#!/usr/bin/env bash
# Uninstall mode tests. All paths point into a temp directory and firewall
# commands are stubbed, so no real system state is changed.

set -Eeuo pipefail

TEST_TMP="$(mktemp -d)"
trap 'rm -rf -- "$TEST_TMP"' EXIT

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

export VPS_SETUP_CONF="${TEST_TMP}/etc/default/vps-setup"
export VPS_SETUP_STATE_DIR="${TEST_TMP}/etc/vps-setup"
export VPS_SETUP_LOG_DIR="${TEST_TMP}/var/log/vps-setup"
export VPS_SETUP_BACKUP_DIR="${TEST_TMP}/var/backups/vps-setup"
export VPS_SETUP_HOME="${TEST_TMP}/lib/vps-setup-toolkit"
export VPS_SETUP_WATCHER="${TEST_TMP}/sbin/vps-firewall-watch"
export VPS_SETUP_UNIT="${TEST_TMP}/etc/systemd/system/vps-firewall-watch.service"
export VPS_SETUP_WRAPPER="${TEST_TMP}/sbin/vps-setup"

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
assert_true(){
  local name="$1"; shift
  if "$@"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$name" >&2; fi
}
assert_false(){
  local name="$1"; shift
  if "$@"; then FAIL=$((FAIL + 1)); printf 'FAIL (should fail) %s\n' "$name" >&2; else PASS=$((PASS + 1)); fi
}

# shellcheck source=../scripts/common.sh
source "${ROOT_DIR}/scripts/common.sh"
# shellcheck source=../scripts/firewall.sh
source "${ROOT_DIR}/scripts/firewall.sh"
# shellcheck source=../scripts/uninstall.sh
source "${ROOT_DIR}/scripts/uninstall.sh"
init_runtime
is_systemd(){ return 1; }

mkdir -p "$TEST_TMP/bin"
cat >"$TEST_TMP/bin/nft" <<'STUB'
#!/usr/bin/env bash
printf 'nft %s\n' "$*" >>"$STUB_LOG"
exit 0
STUB
cat >"$TEST_TMP/bin/ufw" <<'STUB'
#!/usr/bin/env bash
printf 'ufw %s\n' "$*" >>"$STUB_LOG"
if [[ "${1:-}" == "status" ]]; then
  printf '80/tcp ALLOW OUT\n443/tcp ALLOW OUT\n'
fi
exit 0
STUB
chmod +x "$TEST_TMP/bin/nft" "$TEST_TMP/bin/ufw"
export PATH="$TEST_TMP/bin:$PATH"
export STUB_LOG="$TEST_TMP/commands.log"

setup_files(){
  mkdir -p "$INSTALL_DIR" "$(dirname -- "$WATCHER_PATH")" "$(dirname -- "$UNIT_PATH")" \
    "$(dirname -- "$WRAPPER_PATH")" "$(dirname -- "$CONF_FILE")" "$STATE_DIR" "$LOG_DIR"
  printf '%s\n' '# vps-setup config' >"$CONF_FILE"
  printf 'MANAGED_UFW_TCP="80 443"\nMANAGED_UFW_UDP=""\n' >>"$CONF_FILE"
  printf '%s\n' '80/tcp' >"$INBOUND_RULES_FILE"
  printf '%s\n' 'add rule inet cloud_dev vps_docker_forward' >"$NFT_STATE_FILE"
  printf '%s\n' 'toolkit' >"${INSTALL_DIR}/menu.sh"
  printf '%s\n' 'watcher' >"$WATCHER_PATH"
  printf '%s\n' 'unit' >"$UNIT_PATH"
  printf '%s\n' 'wrapper' >"$WRAPPER_PATH"
  printf '%s\n' 'log' >"${LOG_DIR}/setup.log"
  : >"$STUB_LOG"
}

# --- option 1: toolkit only, configuration kept ------------------------------
setup_files
set +e
printf 'UNINSTALL\n' | uninstall_toolkit keep-config >"$TEST_TMP/keep.out" 2>"$TEST_TMP/keep.err"
keep_rc=$?
set -e
check "keep-config exit status" "0" "$keep_rc"
assert_false "toolkit directory removed" test -d "$INSTALL_DIR"
assert_false "watcher removed" test -e "$WATCHER_PATH"
assert_false "systemd unit removed" test -e "$UNIT_PATH"
assert_false "launcher removed" test -e "$WRAPPER_PATH"
assert_true "config file kept" test -f "$CONF_FILE"
assert_true "inbound rules kept" test -f "$INBOUND_RULES_FILE"
assert_true "nft state kept" test -f "$NFT_STATE_FILE"
assert_true "state dir kept" test -d "$STATE_DIR"
assert_true "logs kept" test -f "${LOG_DIR}/setup.log"
assert_false "nft chain not deleted" grep -q 'flush chain' "$STUB_LOG"
assert_false "ufw rules not deleted" grep -q 'delete allow out' "$STUB_LOG"
assert_true "success explains files kept" grep -q 'configuration, state and logs were kept' "$TEST_TMP/keep.err"

# --- option 2: toolkit with all configuration --------------------------------
setup_files
set +e
printf 'UNINSTALL\n' | uninstall_toolkit all >"$TEST_TMP/all.out" 2>"$TEST_TMP/all.err"
all_rc=$?
set -e
check "remove-all exit status" "0" "$all_rc"
assert_false "toolkit directory removed (all)" test -d "$INSTALL_DIR"
assert_false "config file removed" test -e "$CONF_FILE"
assert_false "inbound rules removed" test -e "$INBOUND_RULES_FILE"
assert_false "nft state removed" test -e "$NFT_STATE_FILE"
assert_false "state dir removed" test -d "$STATE_DIR"
assert_false "log dir removed" test -d "$LOG_DIR"
assert_true "managed nft chain flushed" grep -q 'flush chain' "$STUB_LOG"
assert_true "managed UFW rules deleted" grep -q 'delete allow out' "$STUB_LOG"
assert_true "success explains full removal" grep -q 'all of its configuration were removed' "$TEST_TMP/all.err"

# --- invalid mode is rejected -------------------------------------------------
set +e
uninstall_toolkit wrong-mode >"$TEST_TMP/wrong.out" 2>"$TEST_TMP/wrong.err"
wrong_rc=$?
set -e
assert_false "unknown mode exits nonzero" test "$wrong_rc" -eq 0

printf '\nUninstall tests: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
