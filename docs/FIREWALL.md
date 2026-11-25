# Firewall design

This document explains the distinction between outbound service selection, host inbound rules and Docker container forwarding. It follows the safety model in `complete-vps-setup-security-guide.md`.

## Three different things

| Concept | What it does | Managed by |
|---|---|---|
| Outbound service selection | Lets containers connect **to** external SMTP/IMAP/database/S3/API destinations | UFW `allow out` rules + managed nftables chain |
| Host inbound rule | Lets remote clients connect **to** a port listening on the VPS host | UFW `allow from ... to any port ...` |
| Container inbound access | Publishes/proxies a container port to the network | Docker publish/Traefik + forwarding rules; not automated here |

Selecting MySQL/Redis/S3 categories never publishes a database to the Internet. It only permits **outbound** connections.

## Default inbound policy

`ufw_init` adds baseline TCP 22, 80, 443 rules (plus a detected alternate SSH port if `sshd -T` reports one), sets `default deny incoming` / `default allow outgoing`, and enables UFW without deleting unrelated rules.

Additional inbound rules require a trusted IPv4/CIDR. Leaving the source blank means public access and requires confirmation; database/cache/admin ports additionally require a typed `I-UNDERSTAND-PUBLIC-<port>` confirmation. Docker API ports 2375/2376 are always refused.

## Service catalog

`config/services.conf` contains IDs 1-20 from the original guide plus custom TCP (21) and UDP (22). Effective ports are computed from selected IDs + custom ports, normalized (validated, de-duplicated, sorted) and stored in `/etc/default/vps-setup`:

```text
TCP_EGRESS_PORTS="80 443 587 993 23306 24900"
UDP_EGRESS_PORTS=""
SELECTED_SERVICE_IDS="1 5 6 18 19"
CUSTOM_TCP_PORTS=""
CUSTOM_UDP_PORTS=""
MANAGED_UFW_TCP="80 443 587 993 23306 24900"
```

`MANAGED_UFW_*` tracks only rules the toolkit added, so removal never deletes a pre-existing rule that happened to match.

## Dedicated nftables chain

Defaults (overridable in the config file):

```text
NFT_FAMILY=inet
NFT_TABLE=cloud_dev
NFT_PARENT=forward
NFT_MANAGED=vps_docker_forward
```

On each reconcile the toolkit:

1. Verifies the existing parent chain (`inet cloud_dev forward`) is present. If it is missing, it **does not create a competing policy** and returns an error; the watcher retries later.
2. Removes duplicate toolkit jump rules (only rules with comment `VPS-MANAGED-DOCKER-JUMP`).
3. Generates rules for every dynamically detected Docker bridge (`docker0`, `docker_gwbridge`, `br-<hex>`) and its IPv4 subnet, using the default-route interface (or configured `WAN_IF`).
4. Adds at most one `jump vps_docker_forward` into the parent chain.
5. Flushes **only** the managed chain and applies the new rules atomically with `nft -f` after `nft -c -f` validation.

Example generated rule:

```nft
add rule inet cloud_dev vps_docker_forward \
  iifname "br-abc123" oifname "eth0" ip saddr 172.18.0.1/16 \
  tcp dport { 443, 587 } ct state { new, established, related } counter accept
```

The toolkit never runs `nft flush ruleset` and never deletes user chains or rules.

## Docker recovery

On systemd hosts, `vps-firewall-watch.service` runs `/usr/local/sbin/vps-firewall-watch`, which invokes both `firewall.sh nft-reconcile` and `scripts/network.sh reconcile` every `WATCH_INTERVAL` seconds (default 15). On non-systemd Linux hosts the toolkit installs a managed cron entry instead, calling the same reconciler once per minute. If neither systemd nor cron exists, the watcher binary and unit are installed but a warning tells you to supply a supervisor. Because bridge/subnet discovery happens on every pass, the managed chains heal after:

- Docker daemon restart
- bridge/network recreation (`br-*` name or subnet changes)
- server reboot
- accidental removal of the managed chain or jump
- parent chain reappearing after being absent
- WAN MTU or Docker bridge changes that alter the desired MSS rules

If the generated ruleset is unchanged and the chain/jump exist, no write occurs (idempotent and quiet).

The unit uses `Restart=always`, `NoNewPrivileges=true`, `PrivateTmp=true` and read/write paths limited to state/log directories. The cron fallback is marked with `# vps-setup firewall watch (managed)` so uninstall can remove only that line.

UFW is the host-firewall backend the toolkit manages. If UFW is unavailable on a given distribution, base setup warns and skips host-firewall configuration; the toolkit never disables or replaces another firewall (for example firewalld) on its own.

## Container network doctor and scoped MSS repair

Docker-related install paths enable `ENABLE_MSS_CLAMP` and the network reconciler. The doctor is intentionally separate from the nftables/UFW managers: its only possible automatic change is an **iptables mangle** rule set under `VPS-SENTINEL-MSS`.

| Item | Value |
|---|---|
| Managed chain | `VPS-SENTINEL-MSS` in `iptables -t mangle` |
| Jump comment | `VPS-SENTINEL-JUMP` (single commented `FORWARD` jump) |
| Rule comment | `VPS-SENTINEL-MSS <bridge>-<wan>` |
| Desired state | `/etc/vps-setup/network-mss.rules` |
| Change log | `/etc/vps-setup/network-changes.log` |
| Backups | `/var/backups/vps-setup/<timestamp>/iptables-mangle.rules` |

Rules are generated from the default-route interface (or `WAN_IF`) and every discovered Docker bridge/subnet (`docker0`, `docker_gwbridge`, `br-*`). They match only bridge → WAN, IPv4 source subnet, TCP SYN, and clamp to PMTU. The reconciler is idempotent: when interfaces, subnets and WAN are unchanged it writes nothing.

Automatic repair requires all of the following:

1. Host DNS/TCP succeeds while the container fails at TLS/application level.
2. MTU evidence shows a Docker-side MTU greater than the WAN MTU.
3. `ENABLE_MSS_CLAMP=1`.
4. An operator reviews `--dry-run` and types `APPLY-NETWORK-REPAIR`.
5. Fresh-connection verification succeeds; otherwise the change is rolled back automatically.

The doctor reuses the administrator-approved outbound TCP ports as test targets. Set `NETWORK_TARGET_HOST` and `NETWORK_TARGET_PORT` in `/etc/default/vps-setup`, or pass `--target host:port --protocol https|http|...` to a CLI command. `NETWORK_TARGET_PORT` always wins; one allowed TCP port is selected automatically; interactive mode lists multiple allowed ports; non-interactive mode uses the first allowed port.

It never disables UFW/nftables, flushes an entire ruleset, sets policies to ACCEPT, changes physical MTUs, recreates Swarm networks, exposes databases or the Docker API, disables TLS verification, or installs packages inside application containers.

```bash
sudo vps-setup network status
sudo vps-setup network diagnose --container <id> --target host.example.test:443
sudo vps-setup network repair --container <id> --target host.example.test:443 --dry-run
sudo vps-setup network repair --container <id> --target host.example.test:443 --apply
sudo vps-setup network verify --container <id> --target host.example.test:443
sudo vps-setup network rollback [change-id]
sudo vps-setup network mss-status
```

## Guided firewall workflow

Selecting any service-install category (menu items 1-8) triggers:

1. **Pre-install prompt** — UFW defaults (`deny incoming`, `allow outgoing`, baseline SSH/HTTP/HTTPS), the managed nftables chain and the watcher are configured before packages are installed. This prevents the common "database/mail/Docker apps cannot connect" failures caused by applying firewall rules too late.
2. **Post-install prompt** — after the selected services finish, you can configure outbound access via:
   - **one-by-one** (`y/N` per catalog category, including SMTP, IMAP, MySQL, Redis, S3),
   - **standard/reputed preset** — IDs `1 2 3 4 5 6 7 20` (Web/API, DNS, NTP, SSH/Git, SMTP, IMAP, POP3, SMS API),
   - **all 20 documented categories** — the full catalog, still outbound-only,
   - **skip**.

`vps-setup run <ids> --yes` applies the firewall basics and the standard preset without prompting. Set `VPS_SETUP_SKIP_FIREWALL=1` to disable both automatic steps.

## Dokploy / Coolify / Docker ingress (automatic)

When menu item **3**, **4** or **5** is selected, `ENABLE_DOKPLOY_INGRESS` is enabled in `/etc/default/vps-setup`. As soon as `docker_gwbridge` exists, the watcher generates two rules in the managed chain:

```nft
# Allow incoming public HTTP/HTTPS traffic to the current Traefik container
add rule inet cloud_dev vps_docker_forward \
  iifname "<wan>" oifname "docker_gwbridge" \
  ip daddr <traefik-ip> tcp dport { 80, 443 } \
  ct status dnat counter accept comment "DOKPLOY-INGRESS"

# Allow established return traffic from Traefik
add rule inet cloud_dev vps_docker_forward \
  iifname "docker_gwbridge" oifname "<wan>" \
  ip saddr <traefik-ip> ct state { established, related } \
  counter accept comment "DOKPLOY-RETURN"
```

These are the managed-chain equivalent of inserting the same matches into `inet cloud_dev forward`; the chain is jumped from that forward chain, so the effect is identical while keeping all toolkit rules in one place. The Traefik address is read from the running container when Docker is available, otherwise `TRAEFIK_IP` is used (default `10.0.2.2`, overridable in config). `TRAEFIK_BRIDGE` defaults to `docker_gwbridge`.

Because the watcher regenerates the rules from live interfaces, they survive VPS reboots, Docker daemon restarts and bridge re-creation with no manual `nft insert rule` commands. It never exposes dashboard ports or Docker API TCP 2375/2376.

## Verification

```bash
ufw status verbose
nft -a list chain inet cloud_dev vps_docker_forward
nft -a list chain inet cloud_dev vps_docker_forward | grep DOKPLOY   # ingress rules
ip -br -4 addr | grep -E 'docker|br-'
ip -4 route show default
systemctl status vps-firewall-watch.service    # systemd hosts
crontab -l | grep vps-setup                     # cron fallback
journalctl -u vps-firewall-watch.service -n 100 --no-pager
sudo iptables -w -t mangle -S VPS-SENTINEL-MSS
sudo vps-setup network status
sudo vps-setup network mss-status
```

## Rollback

Stop the watcher:

```bash
sudo systemctl disable --now vps-firewall-watch.service   # systemd hosts
# or, on the cron fallback: remove the line containing "vps-setup" from `crontab -e`
```

Remove only toolkit-owned firewall objects after inspection:

```bash
sudo nft -a list chain inet cloud_dev forward
sudo nft -a list chain inet cloud_dev vps_docker_forward
sudo iptables -w -t mangle -S VPS-SENTINEL-MSS
# Menu 13 -> Uninstall -> opt in to "remove managed nftables chain/jump"
```

The uninstall path only deletes jump rules carrying the toolkit comment, then flushes/deletes the managed chain. In `all` mode it also removes `VPS-SENTINEL-MSS`, its commented `FORWARD` jump and the network state/change log. It leaves all other rules untouched. A full ruleset backup is written under `/var/backups/vps-setup/` first.

Immediate one-command rollback without uninstalling: `sudo vps-setup network rollback [change-id]`.
