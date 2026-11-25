#!/usr/bin/env bash
# DNS/domain routing tests with stubbed Cloudflare API, curl and UFW.

set -Eeuo pipefail

TEST_TMP="$(mktemp -d)"
trap 'rm -rf -- "$TEST_TMP"' EXIT
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

mkdir -p "$TEST_TMP/bin" "$TEST_TMP/etc/default" "$TEST_TMP/etc/vps-setup" \
  "$TEST_TMP/var/log/vps-setup" "$TEST_TMP/var/backups/vps-setup" "$TEST_TMP/sbin"

cat >"$TEST_TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -u
outfile=""
with_status=0
args="$*"
for ((i=1; i<=$#; i++)); do
  arg="${!i}"
  if [[ "$arg" == "-o" ]]; then
    j=$((i + 1))
    outfile="${!j:-}"
  fi
  [[ "$arg" == "-w" ]] && with_status=1
done
body=""
if [[ "$args" == *"/ips"* ]]; then
  body='{"success":true,"result":{"ipv4_cidrs":["203.0.113.0/24","198.51.100.0/24"],"ipv6_cidrs":["2001:db8:cf::/48"]}}'
elif [[ "$args" == *"/zones?"* ]]; then
  body='{"success":true,"result":[{"id":"zone123","name":"example.com"}]}'
elif [[ "$args" == *"/dns_records?"* ]]; then
  body='{"success":true,"result":[]}'
else
  body='{"success":true,"result":{"id":"record123"}}'
fi
if [[ "$args" == *"api.ipify.org"* ]]; then
  printf '%s\n' '203.0.113.10'
elif [[ -n "$outfile" ]]; then
  printf '%s\n' "$body" >"$outfile"
  (( with_status == 1 )) && printf '%s\n' '200'
else
  printf '%s\n' "$body"
fi
exit 0
EOF

cat >"$TEST_TMP/bin/ufw" <<'EOF'
#!/usr/bin/env bash
set -u
STATE="${VPS_SETUP_TEST_UFW_STATE:?}"
touch "$STATE"
case "${1:-}" in
  status) printf 'Status: active\n'; cat "$STATE"; exit 0 ;;
  allow|delete)
    action="$1"; shift
    if [[ "${1:-}" == "from" ]]; then
      cidr="$2"; shift 2
      port=""
      while (( $# > 0 )); do
        if [[ "$1" == "port" ]]; then port="${2:-}"; shift 2; else shift; fi
      done
      rule="${port}/tcp ALLOW IN ${cidr} # Cloudflare origin (vps-setup managed)"
      if [[ "$action" == "allow" ]]; then
        grep -Fxq -- "$rule" "$STATE" || printf '%s\n' "$rule" >>"$STATE"
      else
        grep -Fxv -- "$rule" "$STATE" >"$STATE.tmp" || true
        mv "$STATE.tmp" "$STATE"
      fi
    fi
    exit 0
    ;;
esac
exit 0
EOF

cat >"$TEST_TMP/bin/docker" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TEST_TMP/bin/"*

export PATH="$TEST_TMP/bin:$PATH"
export VPS_SETUP_CONF="$TEST_TMP/etc/default/vps-setup"
export VPS_SETUP_STATE_DIR="$TEST_TMP/etc/vps-setup"
export VPS_SETUP_LOG_DIR="$TEST_TMP/var/log/vps-setup"
export VPS_SETUP_LOG_FILE="$VPS_SETUP_LOG_DIR/setup.log"
export VPS_SETUP_BACKUP_DIR="$TEST_TMP/var/backups/vps-setup"
export VPS_SETUP_TEST_UFW_STATE="$TEST_TMP/etc/vps-setup/ufw.rules"
export VPS_SETUP_SOURCE_ROOT="$ROOT_DIR"
export VPS_SETUP_INTERACTIVE=0
export VPS_SETUP_CLOUDFLARE_TOKEN="test-token"
export VPS_SETUP_PUBLIC_IPV4="203.0.113.10"

# shellcheck source=../scripts/common.sh
source "$ROOT_DIR/scripts/common.sh"
# shellcheck source=../scripts/firewall.sh
source "$ROOT_DIR/scripts/firewall.sh"
# shellcheck source=../scripts/network.sh
source "$ROOT_DIR/scripts/network.sh"
run_probe(){ PROBE_LAST_OUTPUT="STUB PROBE"; PROBE_LAST_RC=0; }
# shellcheck source=../scripts/dns.sh
source "$ROOT_DIR/scripts/dns.sh"
init_runtime

PASS=0
FAIL=0
check(){
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then PASS=$((PASS + 1)); else
    FAIL=$((FAIL + 1))
    printf 'FAIL %-45s expected=[%s] actual=[%s]\n' "$name" "$expected" "$actual" >&2
  fi
}
check_true(){
  local name="$1"; shift
  if "$@"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$name" >&2; fi
}

# --- Cloudflare IP ranges and origin allow rules ----------------------------
dns_cf_refresh_ips >/dev/null
check "Cloudflare IPv4 range stored" "2" "$(grep -c '^203.0.113.0/24$\|^198.51.100.0/24$' "$CF_IPS_FILE")"
check "Cloudflare IPv6 range stored" "1" "$(grep -c '2001:db8:cf::/48' "$CF_IPS_FILE")"
dns_cf_origin_apply >/dev/null
check "origin rules for IPv4 HTTP/HTTPS" "2" "$(grep -c '203.0.113.0/24' "$VPS_SETUP_TEST_UFW_STATE")"
check "origin rules for IPv6 HTTP/HTTPS" "2" "$(grep -c '2001:db8:cf::/48' "$VPS_SETUP_TEST_UFW_STATE")"
check "no public broad origin rule added" "0" "$(grep -c 'ALLOW IN Anywhere' "$VPS_SETUP_TEST_UFW_STATE" || true)"

# --- domain configuration ---------------------------------------------------
dns_configure_domain app.example.com nextjs A "" true >/dev/null
check_true "domain state written" grep -q '^app.example.com|cloudflare|A|app.example.com|203.0.113.10|true|zone123|nextjs$' "$DNS_STATE_FILE"
labels_output="$(dns_labels app.example.com nextjs)"
check_true "Traefik label guidance printed" grep -q 'Host(`app.example.com`)' <<<"$labels_output"
dns_list >/dev/null
dns_test_domain app.example.com >/dev/null

# Re-configuring must replace, not duplicate, the stored domain.
dns_configure_domain app.example.com nextjs A "203.0.113.20" false >/dev/null
check "domain state has one entry" "1" "$(grep -c '^app.example.com|' "$DNS_STATE_FILE")"
check_true "updated target stored" grep -q '203.0.113.20' "$DNS_STATE_FILE"

# --- removal and menu -------------------------------------------------------
dns_remove_domain app.example.com >/dev/null
check "domain state empty after removal" "0" "$(grep -c '^app.example.com|' "$DNS_STATE_FILE" || true)"
menu_output="$(printf '0\n' | dns_menu)"
check_true "DNS menu heading" grep -qx '========== DNS & DOMAIN ROUTING ==========' <<<"$menu_output"
check_true "DNS menu option 1" grep -qx '\[1\] Configure a domain (Cloudflare)' <<<"$menu_output"
check_true "DNS menu prompt" grep -qx 'Choose an option:' <<<"$menu_output"

printf '\nDNS tests: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
