# Complete VPS Setup and Firewall Guide

A single interactive Bash installer for Debian 12/13 VPS servers. It supports optional setup categories, a multi-select outbound service firewall menu, custom TCP/UDP outbound ports, optional host inbound ports, and a persistent Docker firewall watcher.

> **Safety defaults:** inbound SSH/HTTP/HTTPS only; outbound service ports are opt-in; database, Redis, S3 and mail ports are never opened publicly by the service selector. The script does not flush the host nftables ruleset or replace your existing firewall chains.

## What it manages

- Base utilities and system updates (optional).
- Node.js via NodeSource and PM2 (optional).
- Docker Engine and Compose plugin (optional).
- Dokploy or Coolify installer launch (optional; review upstream installer before running).
- Nginx and PHP-FPM (optional).
- WordPress prerequisites (optional; WordPress itself is deployed separately).
- SSH hardening suggestions (no automatic SSH port change).
- Explicit outbound TCP/UDP port selections in UFW and a dedicated nftables chain for Docker bridge forwarding.
- Optional host inbound UFW rules, optionally restricted to a trusted source CIDR.
- A systemd watcher that re-detects Docker bridges after reboot or bridge recreation.

## Important networking distinction

- **Outbound service selection** permits containers to initiate connections to external services. It does not expose those services to the public Internet.
- **Host inbound UFW rules** permit connections to services listening on the VPS host. They do not publish a container port.
- **Container inbound access** additionally requires a Docker-published port / proxy route and a matching forwarding policy. Do not publish databases, Redis, Docker API, or management dashboards publicly.
- UFW's default outgoing policy is normally already `allow`; explicit `ufw allow out` rules are retained for clarity and auditability. The dedicated nftables chain is what allows selected Docker bridge egress through a custom restrictive FORWARD chain.

## Default public inbound policy

Keep only the ports you actually need. A typical web VPS needs TCP 22, 80 and 443. Keep Dokploy/Coolify dashboards private or behind an authenticated VPN / access proxy. Never expose Docker API TCP 2375/2376.

## Installation

Save this document's script section as `/root/vps-setup.sh`, then run:

```bash
chmod 700 /root/vps-setup.sh
sudo bash /root/vps-setup.sh
```

Run as root. The script targets Debian 12/13. Review the script before execution, especially if the VPS already has custom firewall rules.

## Single interactive setup script

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

APP="vps-setup"
BIN="/usr/local/sbin/${APP}"
CONF="/etc/default/${APP}"
WATCH_UNIT="vps-firewall-watch.service"
WATCHER="/usr/local/sbin/vps-firewall-watch"
NFT_FAMILY="inet"
NFT_TABLE="cloud_dev"
NFT_PARENT="forward"
NFT_MANAGED="vps_docker_forward"
WAN_IF=""

log(){ printf '\n[%s] %s\n' "$(date '+%F %T')" "$*"; }
warn(){ printf '\n[WARNING] %s\n' "$*" >&2; }
die(){ printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die 'Run this script as root: sudo bash vps-setup.sh'; }

install_packages(){
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl wget gnupg lsb-release jq git ufw nftables iproute2 procps systemd
}

load_config(){
  [[ -f "$CONF" ]] && source "$CONF"
  : "${TCP_EGRESS_PORTS:=}"
  : "${UDP_EGRESS_PORTS:=}"
  : "${ENABLE_DOKPLOY_INGRESS:=0}"
  : "${TRAEFIK_IP:=10.0.2.2}"
  : "${TRAEFIK_BRIDGE:=docker_gwbridge}"
}

save_config(){
  install -d -m 0755 /etc/default
  cat > "$CONF" <<EOFCONF
# Managed by ${APP}. Space-separated port lists.
TCP_EGRESS_PORTS="${TCP_EGRESS_PORTS:-}"
UDP_EGRESS_PORTS="${UDP_EGRESS_PORTS:-}"
ENABLE_DOKPLOY_INGRESS="${ENABLE_DOKPLOY_INGRESS:-0}"
TRAEFIK_IP="${TRAEFIK_IP:-10.0.2.2}"
TRAEFIK_BRIDGE="${TRAEFIK_BRIDGE:-docker_gwbridge}"
EOFCONF
  chmod 600 "$CONF"
}

valid_port(){ [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
normalize_ports(){
  local input="$1" item out=""; local -A seen=()
  for item in $input; do
    valid_port "$item" || die "Invalid port: $item (valid range: 1-65535)"
    item=$((10#$item))
    [[ ${seen[$item]+x} ]] && continue
    seen[$item]=1
    out+="${item} "
  done
  printf '%s' "${out% }"
}

ufw_init(){
  command -v ufw >/dev/null 2>&1 || apt-get install -y ufw
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow 22/tcp comment 'SSH'
  ufw allow 80/tcp comment 'HTTP'
  ufw allow 443/tcp comment 'HTTPS'
  ufw --force enable
  log 'UFW enabled. Existing unrelated rules are not deleted.'
}

ufw_apply_egress(){
  local p
  for p in ${TCP_EGRESS_PORTS:-}; do ufw allow out "$p/tcp" comment 'VPS managed container egress' >/dev/null || true; done
  for p in ${UDP_EGRESS_PORTS:-}; do ufw allow out "$p/udp" comment 'VPS managed container egress' >/dev/null || true; done
}

get_wan(){
  ip -4 route show default 2>/dev/null | awk 'NR==1 {for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}'
}

bridge_inventory(){
  local name
  # Docker bridge networks: docker_gwbridge, docker0, and user-created br-* devices.
  for name in $(ip -o link show 2>/dev/null | sed -nE 's/^[0-9]+: ([^:@]+)(@[^:]+)?:.*/\1/p' | grep -E '^(docker0|docker_gwbridge|br-[[:xdigit:]]+)$' || true); do
    ip -4 -o addr show dev "$name" 2>/dev/null | awk -v n="$name" '{print n, $4}'
  done
}

nft_apply(){
  command -v nft >/dev/null 2>&1 || { warn 'nft command not installed; install nftables first.'; return 1; }
  nft list chain "$NFT_FAMILY" "$NFT_TABLE" "$NFT_PARENT" >/dev/null 2>&1 || {
    warn "Required existing chain ${NFT_FAMILY} ${NFT_TABLE} ${NFT_PARENT} was not found. Not creating or replacing your firewall policy."
    return 1
  }

  nft list table "$NFT_FAMILY" "$NFT_TABLE" >/dev/null 2>&1 || return 1
  nft list chain "$NFT_FAMILY" "$NFT_TABLE" "$NFT_MANAGED" >/dev/null 2>&1 || nft add chain "$NFT_FAMILY" "$NFT_TABLE" "$NFT_MANAGED"

  # Add exactly one jump from the user's existing forward chain to our dedicated chain.
  if ! nft -a list chain "$NFT_FAMILY" "$NFT_TABLE" "$NFT_PARENT" | grep -q "jump ${NFT_MANAGED}"; then
    nft insert rule "$NFT_FAMILY" "$NFT_TABLE" "$NFT_PARENT" jump "$NFT_MANAGED" comment 'VPS-MANAGED-DOCKER-JUMP'
  fi

  # Flush only the dedicated chain created and owned by this script.
  nft flush chain "$NFT_FAMILY" "$NFT_TABLE" "$NFT_MANAGED"

  local wan; wan="$(get_wan)"
  [[ -n "$wan" ]] || { warn 'No default-route interface detected.'; return 1; }

  local bridge subnet
  while read -r bridge subnet; do
    [[ -n "${bridge:-}" && -n "${subnet:-}" ]] || continue
    local tcp_set="" udp_set=""
    [[ -n "${TCP_EGRESS_PORTS:-}" ]] && tcp_set="{ $(echo "$TCP_EGRESS_PORTS" | tr ' ' ',') }"
    [[ -n "${UDP_EGRESS_PORTS:-}" ]] && udp_set="{ $(echo "$UDP_EGRESS_PORTS" | tr ' ' ',') }"

    if [[ -n "$tcp_set" ]]; then
      nft add rule "$NFT_FAMILY" "$NFT_TABLE" "$NFT_MANAGED" iifname "$bridge" oifname "$wan" ip saddr "$subnet" tcp dport "$tcp_set" ct state '{ new, established, related }' counter accept
    fi
    if [[ -n "$udp_set" ]]; then
      nft add rule "$NFT_FAMILY" "$NFT_TABLE" "$NFT_MANAGED" iifname "$bridge" oifname "$wan" ip saddr "$subnet" udp dport "$udp_set" ct state '{ new, established, related }' counter accept
    fi
    # Permit return packets for connections initiated by containers.
    nft add rule "$NFT_FAMILY" "$NFT_TABLE" "$NFT_MANAGED" iifname "$wan" oifname "$bridge" ip daddr "$subnet" ct state '{ established, related }' counter accept
  done < <(bridge_inventory)

  # Optional HTTP/HTTPS DNAT forwarding to Dokploy's Traefik gateway only.
  if [[ "${ENABLE_DOKPLOY_INGRESS:-0}" == "1" ]]; then
    if ip link show "$TRAEFIK_BRIDGE" >/dev/null 2>&1; then
      nft add rule "$NFT_FAMILY" "$NFT_TABLE" "$NFT_MANAGED" iifname "$wan" oifname "$TRAEFIK_BRIDGE" ip daddr "$TRAEFIK_IP" tcp dport '{ 80, 443 }' ct status dnat counter accept
    else
      warn "Dokploy ingress enabled, but bridge ${TRAEFIK_BRIDGE} is not present yet. Watcher will retry."
    fi
  fi
}

apply_firewall(){
  load_config
  TCP_EGRESS_PORTS="$(normalize_ports "${TCP_EGRESS_PORTS:-}")"
  UDP_EGRESS_PORTS="$(normalize_ports "${UDP_EGRESS_PORTS:-}")"
  save_config
  ufw_apply_egress
  nft_apply || warn 'nftables policy was not applied; check the existing cloud_dev forward chain and watcher logs.'
}

start_watcher(){
  cat > "$WATCHER" <<'EOFWATCH'
#!/usr/bin/env bash
set -u
CONF=/etc/default/vps-setup
NFT_FAMILY=inet
NFT_TABLE=cloud_dev
NFT_PARENT=forward
NFT_MANAGED=vps_docker_forward
while true; do
  if [[ -f "$CONF" ]]; then
    # shellcheck disable=SC1091
    source "$CONF"
    wan=$(ip -4 route show default 2>/dev/null | awk 'NR==1 {for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
    bridges=$(for b in $(ip -o link show 2>/dev/null | sed -nE 's/^[0-9]+: ([^:@]+)(@[^:]+)?:.*/\1/p' | grep -E '^(docker0|docker_gwbridge|br-[[:xdigit:]]+)$' || true); do ip -4 -o addr show dev "$b" 2>/dev/null | awk -v n="$b" '{print n, $4}'; done)
    # Re-apply the managed chain on every pass. Only this dedicated chain is flushed.
    if [[ -n "$wan" ]] && nft list chain "$NFT_FAMILY" "$NFT_TABLE" "$NFT_PARENT" >/dev/null 2>&1; then
      nft list chain "$NFT_FAMILY" "$NFT_TABLE" "$NFT_MANAGED" >/dev/null 2>&1 || nft add chain "$NFT_FAMILY" "$NFT_TABLE" "$NFT_MANAGED" 2>/dev/null || true
      if nft list chain "$NFT_FAMILY" "$NFT_TABLE" "$NFT_MANAGED" >/dev/null 2>&1; then
        if ! nft -a list chain "$NFT_FAMILY" "$NFT_TABLE" "$NFT_PARENT" 2>/dev/null | grep -q "jump ${NFT_MANAGED}"; then
          nft insert rule "$NFT_FAMILY" "$NFT_TABLE" "$NFT_PARENT" jump "$NFT_MANAGED" comment 'VPS-MANAGED-DOCKER-JUMP' 2>/dev/null || true
        fi
        nft flush chain "$NFT_FAMILY" "$NFT_TABLE" "$NFT_MANAGED" 2>/dev/null || true
        tcp_set=""; udp_set=""
        [[ -n "${TCP_EGRESS_PORTS:-}" ]] && tcp_set="{ $(echo "$TCP_EGRESS_PORTS" | tr ' ' ',') }"
        [[ -n "${UDP_EGRESS_PORTS:-}" ]] && udp_set="{ $(echo "$UDP_EGRESS_PORTS" | tr ' ' ',') }"
        while read -r bridge subnet; do
          [[ -n "${bridge:-}" && -n "${subnet:-}" ]] || continue
          if [[ -n "$tcp_set" ]]; then nft add rule "$NFT_FAMILY" "$NFT_TABLE" "$NFT_MANAGED" iifname "$bridge" oifname "$wan" ip saddr "$subnet" tcp dport "$tcp_set" ct state '{ new, established, related }' counter accept 2>/dev/null || true; fi
          if [[ -n "$udp_set" ]]; then nft add rule "$NFT_FAMILY" "$NFT_TABLE" "$NFT_MANAGED" iifname "$bridge" oifname "$wan" ip saddr "$subnet" udp dport "$udp_set" ct state '{ new, established, related }' counter accept 2>/dev/null || true; fi
          nft add rule "$NFT_FAMILY" "$NFT_TABLE" "$NFT_MANAGED" iifname "$wan" oifname "$bridge" ip daddr "$subnet" ct state '{ established, related }' counter accept 2>/dev/null || true
        done <<< "$bridges"
        if [[ "${ENABLE_DOKPLOY_INGRESS:-0}" == "1" ]] && ip link show "${TRAEFIK_BRIDGE:-docker_gwbridge}" >/dev/null 2>&1; then
          nft add rule "$NFT_FAMILY" "$NFT_TABLE" "$NFT_MANAGED" iifname "$wan" oifname "${TRAEFIK_BRIDGE:-docker_gwbridge}" ip daddr "${TRAEFIK_IP:-10.0.2.2}" tcp dport '{ 80, 443 }' ct status dnat counter accept 2>/dev/null || true
        fi
      fi
    fi
  fi
  sleep 15
done
EOFWATCH
  chmod 750 "$WATCHER"
  cat > "/etc/systemd/system/${WATCH_UNIT}" <<EOFUNIT
[Unit]
Description=Persistent Docker bridge firewall reconciler
After=network-online.target nftables.service docker.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=${WATCHER}
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOFUNIT
  systemctl daemon-reload
  systemctl enable --now "$WATCH_UNIT"
  log 'Persistent firewall watcher enabled.'
}

multi_select_services(){
  load_config
  cat <<'MENU'

Outbound service categories (select multiple numbers, comma-separated):
 1) Web/API                 TCP: 80,443
 2) DNS                     TCP/UDP: 53
 3) NTP                     UDP: 123
 4) SSH/Git                 TCP: 22
 5) SMTP                    TCP: 25,465,587
 6) IMAP                    TCP: 143,993
 7) POP3                    TCP: 110,995
 8) MySQL/MariaDB           TCP: 3306
 9) PostgreSQL              TCP: 5432
10) Microsoft SQL Server    TCP: 1433
11) Oracle                  TCP: 1521
12) Redis                   TCP: 6379
13) MongoDB                 TCP: 27017
14) S3/MinIO common         TCP: 9000
15) Elasticsearch           TCP: 9200,9300
16) RabbitMQ                TCP: 5671,5672
17) MQTT                    TCP: 1883,8883
18) Nixtec external MariaDB TCP: 23306
19) Nixtec Garage/S3        TCP: 24900
20) SMS/REST API            TCP: 443
21) Custom TCP ports
22) Custom UDP ports
 0) Cancel
MENU
  read -rp 'Select categories (example: 5,6,18,19): ' choices
  [[ "$choices" == "0" || -z "$choices" ]] && return 0
  local tcp="${TCP_EGRESS_PORTS:-}" udp="${UDP_EGRESS_PORTS:-}" choice
  IFS=',' read -ra selected <<< "$choices"
  for choice in "${selected[@]}"; do
    choice="${choice//[[:space:]]/}"
    case "$choice" in
      1) tcp+=" 80 443";; 2) tcp+=" 53"; udp+=" 53";; 3) udp+=" 123";;
      4) tcp+=" 22";; 5) tcp+=" 25 465 587";; 6) tcp+=" 143 993";;
      7) tcp+=" 110 995";; 8) tcp+=" 3306";; 9) tcp+=" 5432";;
      10) tcp+=" 1433";; 11) tcp+=" 1521";; 12) tcp+=" 6379";;
      13) tcp+=" 27017";; 14) tcp+=" 9000";; 15) tcp+=" 9200 9300";;
      16) tcp+=" 5671 5672";; 17) tcp+=" 1883 8883";;
      18) tcp+=" 23306";; 19) tcp+=" 24900";; 20) tcp+=" 443";;
      21) read -rp 'Enter custom TCP ports (space-separated): ' extra; tcp+=" $extra";;
      22) read -rp 'Enter custom UDP ports (space-separated): ' extra; udp+=" $extra";;
      *) warn "Ignoring unknown selection: $choice";;
    esac
  done
  TCP_EGRESS_PORTS="$(normalize_ports "$tcp")"
  UDP_EGRESS_PORTS="$(normalize_ports "$udp")"
  echo
  echo "TCP outbound ports: ${TCP_EGRESS_PORTS:-none}"
  echo "UDP outbound ports: ${UDP_EGRESS_PORTS:-none}"
  read -rp 'Apply these outbound rules to UFW and managed nftables? [y/N]: ' confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { log 'Cancelled; no changes made.'; return 0; }
  save_config
  ufw_apply_egress
  nft_apply || warn 'nftables could not be updated now; watcher will retry when the required chain exists.'
  start_watcher
  log 'Selected outbound service ports saved and applied.'
}

custom_host_inbound(){
  local port proto source
  read -rp 'Host service port to allow inbound (1-65535): ' port
  valid_port "$port" || die 'Invalid port.'
  port=$((10#$port))
  read -rp 'Protocol (tcp/udp): ' proto; proto="${proto,,}"
  [[ "$proto" == tcp || "$proto" == udp ]] || die 'Protocol must be tcp or udp.'
  read -rp 'Trusted source IPv4/CIDR (blank means ANY source / public): ' source
  if [[ -n "$source" ]]; then
    ufw allow from "$source" to any port "$port" proto "$proto" comment 'Custom host inbound'
  else
    warn 'This permits the port from any IPv4 source. Continue only if the service is intended to be public.'
    read -rp 'Confirm public inbound access? [y/N]: ' yes
    [[ "$yes" =~ ^[Yy]$ ]] || return 0
    ufw allow "$port/$proto" comment 'Custom public host inbound'
  fi
  log "UFW host INPUT rule added for ${port}/${proto}. This does not publish a Docker container port."
}

install_node_pm2(){
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -y nodejs
  npm install -g pm2
  node --version; npm --version; pm2 --version
}

install_docker(){
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  . /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  docker version
}

install_nginx_php(){
  apt-get install -y nginx php-fpm php-cli php-mysql php-curl php-gd php-mbstring php-xml php-zip php-intl php-bcmath
  systemctl enable --now nginx
}

launch_dokploy(){
  warn 'Dokploy installation changes Docker/Traefik networking. Review the official installation instructions first.'
  read -rp 'Run the official Dokploy installer now? [y/N]: ' yes
  [[ "$yes" =~ ^[Yy]$ ]] || return 0
  curl -sSL https://dokploy.com/install.sh | sh
  read -rp 'Enable managed HTTP/HTTPS DNAT forwarding to Traefik at 10.0.2.2 on docker_gwbridge? [y/N]: ' ingress
  if [[ "$ingress" =~ ^[Yy]$ ]]; then ENABLE_DOKPLOY_INGRESS=1; save_config; nft_apply || true; fi
}

launch_coolify(){
  warn 'Coolify installation changes Docker and firewall configuration. Review the official Coolify documentation first.'
  read -rp 'Run the official Coolify installer now? [y/N]: ' yes
  [[ "$yes" =~ ^[Yy]$ ]] || return 0
  curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash
}

ssh_security_notes(){
  cat <<'NOTES'

SSH security checklist (manual review recommended):
- Keep a second SSH session open before changing sshd settings.
- Use SSH keys and test key login before disabling password authentication.
- Validate configuration with: sshd -t
- Reload with: systemctl reload ssh
- Do not change the SSH port unless the matching firewall rule is added first.
- Keep root login policy intentional; do not lock yourself out.
NOTES
}

show_status(){
  load_config
  echo '===== UFW ====='; ufw status numbered || true
  echo; echo '===== Managed config ====='; cat "$CONF" 2>/dev/null || true
  echo; echo '===== Docker bridges ====='; bridge_inventory || true
  echo; echo '===== nftables managed chain ====='; nft list chain "$NFT_FAMILY" "$NFT_TABLE" "$NFT_MANAGED" 2>/dev/null || true
  echo; echo '===== Watcher ====='; systemctl --no-pager --full status "$WATCH_UNIT" 2>/dev/null || true
}

main_menu(){
  while true; do
    cat <<'MENU'

========== VPS SETUP MENU ==========
 1) Base utilities / update packages
 2) Node.js + PM2
 3) Docker Engine + Compose
 4) Dokploy
 5) Coolify
 6) Nginx + PHP-FPM
 7) WordPress prerequisites (Nginx/PHP only)
 8) SSH security checklist
 9) Select one or multiple outbound service ports and apply firewall
10) Add custom PUBLIC/RESTRICTED host inbound port (UFW)
11) Install/repair persistent Docker firewall watcher
12) Show firewall / Docker status
 0) Exit
MENU
    read -rp 'Choose an option: ' choice
    case "$choice" in
      1) install_packages; ufw_init;;
      2) install_node_pm2;;
      3) install_docker; start_watcher;;
      4) launch_dokploy; start_watcher;;
      5) launch_coolify; start_watcher;;
      6|7) install_nginx_php;;
      8) ssh_security_notes;;
      9) multi_select_services;;
      10) custom_host_inbound;;
      11) start_watcher; apply_firewall;;
      12) show_status;;
      0) exit 0;;
      *) warn 'Invalid menu choice.';;
    esac
  done
}

need_root
[[ -r /etc/os-release ]] || die 'Cannot identify operating system.'
. /etc/os-release
[[ "${ID:-}" == debian ]] || warn "Designed for Debian; detected ${PRETTY_NAME:-unknown}."
load_config
main_menu
```

## Recommended service selections for the Nixtec VPS

For the external services previously configured, choose:

- **SMTP submission:** TCP 587 (STARTTLS). Use TCP 465 only if the provider specifically requires implicit TLS.
- **IMAP:** TCP 993 (implicit TLS). TCP 143 only if using STARTTLS and the provider supports it.
- **External MariaDB:** TCP 23306.
- **Garage S3 endpoint:** TCP 24900.
- **HTTPS APIs / SMS gateways:** TCP 443 (usually already selected by Web/API).

Example multi-select input: `5,6,18,19,20`.

Do not select inbound access for these remote service ports. They are destinations your applications connect to, not ports that should listen publicly on this VPS.

## Validation and troubleshooting

```bash
# Check UFW
ufw status verbose

# Check the custom nftables chain and counters
nft -a list chain inet cloud_dev vps_docker_forward

# Check Docker bridges and addresses
ip -br link | grep -E 'docker|br-'
ip -br -4 addr | grep -E 'docker|br-'

# Check watcher
systemctl status vps-firewall-watch.service
journalctl -u vps-firewall-watch.service -n 100 --no-pager

# Check the default route interface
ip -4 route show default
```

If `inet cloud_dev forward` does not exist, the script intentionally does not create a new competing firewall policy. Adapt the `NFT_TABLE` and `NFT_PARENT` variables to the actual existing table/chain after reviewing `nft list ruleset`.

If Docker egress still fails, inspect the actual bridge, source subnet, default route interface, NAT/masquerade rules, and provider firewall. The managed chain only permits the selected ports; it does not create Docker NAT, DNS configuration, provider-side allow rules, or application TLS settings.

## Rollback

The script does not flush or delete your existing firewall rules. To stop the watcher:

```bash
systemctl disable --now vps-firewall-watch.service
```

To remove only the managed jump and chain, first inspect the rules and confirm the comment/name. Then remove the `jump vps_docker_forward` rule from `inet cloud_dev forward` and delete the managed chain:

```bash
nft -a list chain inet cloud_dev forward
nft flush chain inet cloud_dev vps_docker_forward
nft delete chain inet cloud_dev vps_docker_forward
```

Do not run the deletion commands if other rules or services depend on this managed chain. Remove the systemd unit and watcher only after confirming they are no longer needed:

```bash
rm -f /etc/systemd/system/vps-firewall-watch.service
rm -f /usr/local/sbin/vps-firewall-watch
systemctl daemon-reload
```

## Operational cautions

1. The script deliberately does not open database, Redis, S3, SMTP or IMAP ports inbound by default.
2. Docker-published ports may interact with UFW differently depending on Docker's firewall backend and rules. Verify from an external network after every inbound publishing change.
3. Do not expose Dokploy/Coolify admin ports, PostgreSQL, MariaDB, Redis, MongoDB, Elasticsearch or Docker API directly to the Internet.
4. Keep a provider console or rescue access available before modifying firewall policies.
5. Back up the existing ruleset before major changes: `nft list ruleset > /root/nftables-backup-$(date +%F-%H%M%S).nft`.
6. The watcher reconciles Docker bridge egress rules every 15 seconds. It does not replace Docker's own network setup or provider firewall configuration.
