#!/usr/bin/env bash
# OS/package-manager detection tests using fixtures and stub commands.

set -Eeuo pipefail

TEST_TMP="$(mktemp -d)"
trap 'rm -rf -- "$TEST_TMP"' EXIT
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
mkdir -p "$TEST_TMP/bin" "$TEST_TMP/releases"

cat >"$TEST_TMP/bin/dpkg" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "--print-architecture" ]] && echo amd64
exit 0
EOF
cat >"$TEST_TMP/bin/rpm" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "--eval" ]] && echo x86_64
exit 1
EOF
for tool in dnf yum apk pacman zypper rc-service systemctl chkconfig; do
  cat >"$TEST_TMP/bin/$tool" <<EOF
#!/usr/bin/env bash
printf '%s %s\\n' "$tool" "\$*" >>"\$TEST_LOG_DIR/pkg.log"
exit 0
EOF
done
chmod 0755 "$TEST_TMP/bin"/*

export PATH="${TEST_TMP}/bin:${PATH}"
export TEST_LOG_DIR="$TEST_TMP"
export VPS_SETUP_OS_RELEASE="$TEST_TMP/releases/os-release"
export VPS_SETUP_INIT_SYSTEM="systemd"
export VPS_SETUP_UNAME_S="Linux"
export VPS_SETUP_CONF="$TEST_TMP/etc/default/vps-setup"
export VPS_SETUP_STATE_DIR="$TEST_TMP/etc/vps-setup"
export VPS_SETUP_LOG_DIR="$TEST_TMP/var/log/vps-setup"
export VPS_SETUP_LOG_FILE="${VPS_SETUP_LOG_DIR}/setup.log"
export VPS_SETUP_BACKUP_DIR="$TEST_TMP/var/backups/vps-setup"
export VPS_SETUP_SOURCE_ROOT="$ROOT_DIR"

# shellcheck source=../scripts/common.sh
source "$ROOT_DIR/scripts/common.sh"
init_runtime

PASS=0
FAIL=0
check(){
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); printf 'FAIL %-40s expected=[%s] actual=[%s]\n' "$name" "$expected" "$actual" >&2
  fi
}

fixture(){
  cat >"$VPS_SETUP_OS_RELEASE" <<EOF
ID="$1"
VERSION_ID="$2"
ID_LIKE="$3"
PRETTY_NAME="Fixture $1 $2"
VERSION_CODENAME="$4"
EOF
  detect_os
}

fixture debian 12 "" bookworm
check "debian family" "debian" "$OS_FAMILY"
check "debian package manager" "apt" "$PKG_MANAGER"
check "debian arch" "amd64" "$ARCH"
require_supported_os
check "debian supported" "1" "$OS_SUPPORTED"

fixture ubuntu 24.04 debian noble
check "ubuntu family" "debian" "$OS_FAMILY"
check "ubuntu package manager" "apt" "$PKG_MANAGER"
check "ubuntu codename" "noble" "$OS_CODENAME"

fixture centos 9 "rhel fedora" ""
check "centos family" "rhel" "$OS_FAMILY"
check "centos package manager" "dnf" "$PKG_MANAGER"
require_supported_os
check "centos not in primary matrix" "0" "$OS_SUPPORTED"

fixture fedora 41 "" ""
check "fedora family" "rhel" "$OS_FAMILY"

fixture alpine 3.20 "" ""
check "alpine family" "alpine" "$OS_FAMILY"
check "alpine package manager" "apk" "$PKG_MANAGER"

fixture arch "" "" ""
check "arch family" "arch" "$OS_FAMILY"
check "arch package manager" "pacman" "$PKG_MANAGER"

fixture opensuse-leap 15.6 "suse opensuse" ""
check "suse family" "suse" "$OS_FAMILY"
check "suse package manager" "zypper" "$PKG_MANAGER"

fixture genericos 1 "" ""
check "unknown family" "unknown" "$OS_FAMILY"
check "unknown family falls back to detected manager" "dnf" "$PKG_MANAGER"

# Dispatch checks: no real packages are installed, stubs only log arguments.
fixture centos 9 "rhel fedora" ""
: >"$TEST_LOG_DIR/pkg.log"
pkg_install curl
check "dnf install command" "dnf -y install curl" "$(grep 'dnf -y install curl' "$TEST_LOG_DIR/pkg.log" | tail -1)"
check "dnf makecache called" "1" "$(grep -c 'dnf -y makecache' "$TEST_LOG_DIR/pkg.log")"

: >"$TEST_LOG_DIR/pkg.log"
service_enable nginx
check "systemd service enable" "systemctl enable --now nginx" "$(cat "$TEST_LOG_DIR/pkg.log")"
check "ssh service default" "ssh" "$(ssh_service_name)"

printf '\nOS detection tests: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
