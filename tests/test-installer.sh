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
printf '%s\n' '#!/usr/bin/env bash' 'echo fake-common' >"$FAKE_SRC/scripts/common.sh"
printf '%s\n' '1|Web|80|443|test' >"$FAKE_SRC/config/services.conf"
printf '%s\n' '#!/usr/bin/env bash' 'echo fake-menu' >"$FAKE_SRC/menu.sh"
printf '%s\n' '#!/usr/bin/env bash' 'echo fake-installer' >"$FAKE_SRC/install.sh"
chmod +x "$FAKE_SRC/menu.sh"
tar -czf "$TEST_TMP/good.tar.gz" -C "$FAKE_SRC" .

# Archive that is missing menu.sh: the installer must refuse to report success.
BROKEN_SRC="$TEST_TMP/broken-source"
mkdir -p "$BROKEN_SRC/scripts" "$BROKEN_SRC/config"
cp "$FAKE_SRC/scripts/common.sh" "$BROKEN_SRC/scripts/common.sh"
cp "$FAKE_SRC/config/services.conf" "$BROKEN_SRC/config/services.conf"
cp "$FAKE_SRC/install.sh" "$BROKEN_SRC/install.sh"
tar -czf "$TEST_TMP/broken.tar.gz" -C "$BROKEN_SRC" .

mkdir -p "$TEST_TMP/bin"
cat >"$TEST_TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
out=""
while (( $# > 0 )); do
  case "$1" in
    -o) out="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "$out" ]] || exit 1
cp -- "$FAKE_ARCHIVE" "$out"
STUB
chmod +x "$TEST_TMP/bin/curl"

# Stub the root check only; everything else is the real installer code.
awk '{ if ($0 == "need_root") print ": # root check stubbed for tests"; else print }' \
  "$ROOT_DIR/install.sh" >"$TEST_TMP/install-under-test.sh"

run_installer(){
  local archive="$1" home="$2" wrapper="$3" label="$4"
  mkdir -p -- "$(dirname -- "$wrapper")"
  (
    cd -- "$TEST_TMP"
    FAKE_ARCHIVE="$archive" \
    PATH="$TEST_TMP/bin:$PATH" \
    VPS_SETUP_HOME="$home" \
    VPS_SETUP_WRAPPER="$wrapper" \
    VPS_SETUP_ARCHIVE_URL="file:///fake/archive.tar.gz" \
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

# --- incomplete archive is rejected ----------------------------------------
BAD_HOME="$TEST_TMP/install-bad"
BAD_WRAPPER="$TEST_TMP/sbin/vps-setup-bad"
set +e
run_installer "$TEST_TMP/broken.tar.gz" "$BAD_HOME" "$BAD_WRAPPER" bad
bad_rc=$?
set -e
assert_false "incomplete archive exits nonzero" test "$bad_rc" -eq 0
assert_true "incomplete archive reports an error" grep -q "\[ERROR\]" "$TEST_TMP/bad.stderr.log"
assert_false "incomplete archive does not report success" grep -q "Installation complete" "$TEST_TMP/bad.stdout.log"

printf '\nInstaller tests: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
