#!/usr/bin/env bash
# Installer bootstrap tests. Uses a fake archive and a stubbed curl so no
# network or real system directories are touched.

set -Eeuo pipefail

TEST_TMP="$(mktemp -d)"
trap 'rm -rf -- "$TEST_TMP"' EXIT

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

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

# --- fixtures ---------------------------------------------------------------
FAKE_SRC="$TEST_TMP/fake-source"
mkdir -p "$FAKE_SRC/scripts" "$FAKE_SRC/config"
cp "$ROOT_DIR/menu.sh" "$ROOT_DIR/install.sh" "$FAKE_SRC/"
cp "$ROOT_DIR"/scripts/*.sh "$FAKE_SRC/scripts/"
cp "$ROOT_DIR/config/services.conf" "$FAKE_SRC/config/"
chmod +x "$FAKE_SRC/menu.sh" "$FAKE_SRC/install.sh"
tar -czf "$TEST_TMP/good.tar.gz" -C "$FAKE_SRC" .

# Layout passes the bootstrap check but install.sh is missing, so the
# post-copy verification must reject it instead of reporting success.
BROKEN_SRC="$TEST_TMP/broken-source"
mkdir -p "$BROKEN_SRC/scripts" "$BROKEN_SRC/config"
cp "$ROOT_DIR/menu.sh" "$BROKEN_SRC/"
cp "$ROOT_DIR"/scripts/*.sh "$BROKEN_SRC/scripts/"
cp "$ROOT_DIR/config/services.conf" "$BROKEN_SRC/config/"
tar -czf "$TEST_TMP/broken.tar.gz" -C "$BROKEN_SRC" .

mkdir -p "$TEST_TMP/bin"
cat >"$TEST_TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
out=""
url=""
while (( $# > 0 )); do
  case "$1" in
    -o) out="${2:-}"; shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
[[ -n "$out" ]] || exit 1
if [[ "$url" == *.sha256 ]]; then
  printf '%s\n' "$FAKE_SHA256" >"$out"
else
  cp -- "$FAKE_ARCHIVE" "$out"
fi
STUB
chmod +x "$TEST_TMP/bin/curl"

# Stub the root check only; everything else is the real installer code.
awk '{ if ($0 == "need_root") print ": # root check stubbed for tests"; else print }' \
  "$ROOT_DIR/install.sh" >"$TEST_TMP/install-under-test.sh"

run_installer(){
  local archive="$1" home="$2" wrapper="$3" label="$4" checksum="${5:-}"
  mkdir -p -- "$(dirname -- "$wrapper")"
  [[ -n "$checksum" ]] || checksum="$(sha256sum "$archive" | awk '{print $1}')"
  (
    cd -- "$TEST_TMP"
    FAKE_ARCHIVE="$archive" \
    FAKE_SHA256="$checksum" \
    PATH="$TEST_TMP/bin:$PATH" \
    VPS_SETUP_HOME="$home" \
    VPS_SETUP_WRAPPER="$wrapper" \
    VPS_SETUP_INSTALL_ONLY=1 \
      bash "$TEST_TMP/install-under-test.sh" >"$TEST_TMP/${label}.stdout.log" 2>"$TEST_TMP/${label}.stderr.log"
  )
}

# --- remote bootstrap installs the menu -------------------------------------
GOOD_HOME="$TEST_TMP/install-good"
GOOD_WRAPPER="$TEST_TMP/sbin/vps-setup-good"
set +e
run_installer "$TEST_TMP/good.tar.gz" "$GOOD_HOME" "$GOOD_WRAPPER" good
install_rc=$?
set -e
check "remote bootstrap exit status" "0" "$install_rc"
assert_true "menu.sh installed" test -f "$GOOD_HOME/menu.sh"
assert_true "scripts/common.sh installed" test -f "$GOOD_HOME/scripts/common.sh"
assert_true "config/services.conf installed" test -f "$GOOD_HOME/config/services.conf"
assert_true "wrapper installed" test -x "$GOOD_WRAPPER"
check_true_wrapper(){ grep -q "$GOOD_HOME/menu.sh" "$GOOD_WRAPPER"; }
assert_true "wrapper points at installed menu" check_true_wrapper
assert_true "completion logged" grep -q "Installation complete" "$TEST_TMP/good.stdout.log"
assert_true "download status goes to stderr" grep -q "Downloading toolkit archive" "$TEST_TMP/good.stderr.log"
assert_true "published checksum verified" grep -q "verified against the published checksum" "$TEST_TMP/good.stderr.log"
assert_false "no verification warning" grep -q "No SHA-256 or GPG verification" "$TEST_TMP/good.stderr.log"

# The menu sources every module at startup, even for --help; this catches
# broken source paths that a syntax-only check would miss.
set +e
bash "$GOOD_HOME/menu.sh" --help >"$TEST_TMP/menu.stdout.log" 2>"$TEST_TMP/menu.stderr.log"
menu_rc=$?
set -e
check "installed menu starts" "0" "$menu_rc"
assert_true "installed menu shows usage" grep -q "Usage:" "$TEST_TMP/menu.stdout.log"
assert_true "usage lists network commands" grep -q "vps-setup network STATUS" "$TEST_TMP/menu.stdout.log"
assert_true "network module installed" test -f "$GOOD_HOME/scripts/network.sh"
assert_true "banner shown before help" grep -q "VPS SENTINEL" "$TEST_TMP/menu.stdout.log"
assert_false "installed menu has no source errors" grep -q "No such file or directory" "$TEST_TMP/menu.stderr.log"

# Simulate the first interactive launch (the installer execs the menu with no
# args) and confirm the banner appears before the menu.
awk '{ line=$0; gsub(/^[[:space:]]+|[[:space:]]+$/, "", line); if (line == "need_root") print ": # root check stubbed for tests"; else print }' \
  "$GOOD_HOME/menu.sh" >"$GOOD_HOME/menu-interactive.sh"
set +e
printf '0\n' | bash "$GOOD_HOME/menu-interactive.sh" >"$TEST_TMP/menu-interactive.log" 2>&1
interactive_rc=$?
set -e
check "interactive menu exits cleanly" "0" "$interactive_rc"
assert_true "banner shown on first menu launch" grep -q "VPS SENTINEL" "$TEST_TMP/menu-interactive.log"
assert_true "menu shown after banner" grep -q "VPS SETUP MENU" "$TEST_TMP/menu-interactive.log"
assert_true "menu lists Container Network Doctor" grep -q "14) Container Network Doctor" "$TEST_TMP/menu-interactive.log"
assert_true "menu lists Unified Service Access" grep -q "15) Unified Service Access" "$TEST_TMP/menu-interactive.log"

# --- checksum mismatch is rejected -----------------------------------------
MISMATCH_HOME="$TEST_TMP/install-mismatch"
MISMATCH_WRAPPER="$TEST_TMP/sbin/vps-setup-mismatch"
set +e
run_installer "$TEST_TMP/good.tar.gz" "$MISMATCH_HOME" "$MISMATCH_WRAPPER" mismatch \
  "0000000000000000000000000000000000000000000000000000000000000000"
mismatch_rc=$?
set -e
assert_false "checksum mismatch exits nonzero" test "$mismatch_rc" -eq 0
assert_true "checksum mismatch reports failure" grep -q "SHA-256 verification failed" "$TEST_TMP/mismatch.stderr.log"
assert_false "checksum mismatch does not install menu" test -f "$MISMATCH_HOME/menu.sh"

# --- incomplete archive is rejected ----------------------------------------
BAD_HOME="$TEST_TMP/install-bad"
BAD_WRAPPER="$TEST_TMP/sbin/vps-setup-bad"
set +e
run_installer "$TEST_TMP/broken.tar.gz" "$BAD_HOME" "$BAD_WRAPPER" bad
bad_rc=$?
set -e
assert_false "incomplete archive exits nonzero" test "$bad_rc" -eq 0
assert_true "incomplete archive reports missing file" grep -q "Installation is incomplete" "$TEST_TMP/bad.stderr.log"
assert_false "incomplete archive does not report success" grep -q "Installation complete" "$TEST_TMP/bad.stdout.log"

printf '\nInstaller tests: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
