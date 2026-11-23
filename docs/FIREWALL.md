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

On systemd hosts, `vps-firewall-watch.service` runs `/usr/local/sbin/vps-firewall-watch`, which invokes `firewall.sh nft-reconcile` every `WATCH_INTERVAL` seconds (default 15). On non-systemd Linux hosts the toolkit installs a managed cron entry instead, calling `firewall.sh nft-reconcile` once per minute. If neither systemd nor cron exists, the watcher binary and unit are installed but a warning tells you to supply a supervisor. Because bridge/subnet discovery happens on every pass, the managed chain heals after:

- Docker daemon restart
- bridge/network recreation (`br-*` name or subnet changes)
- server reboot
- accidental removal of the managed chain or jump
- parent chain reappearing after being absent

If the generated ruleset is unchanged and the chain/jump exist, no write occurs (idempotent and quiet).

The unit uses `Restart=always`, `NoNewPrivileges=true`, `PrivateTmp=true` and read/write paths limited to state/log directories. The cron fallback is marked with `# vps-setup firewall watch (managed)` so uninstall can remove only that line.

UFW is the host-firewall backend the toolkit manages. If UFW is unavailable on a given distribution, base setup warns and skips host-firewall configuration; the toolkit never disables or replaces another firewall (for example firewalld) on its own.

## Dokploy ingress (optional)

When enabled, the managed chain allows already-DNATed TCP 80/443 from the WAN to a configurable Traefik address on `docker_gwbridge` (`TRAEFIK_IP`, `TRAEFIK_BRIDGE`). It never exposes the dashboard ports and never opens Docker API TCP 2375/2376.

## Verification

```bash
ufw status verbose
nft -a list chain inet cloud_dev vps_docker_forward
ip -br -4 addr | grep -E 'docker|br-'
ip -4 route show default
systemctl status vps-firewall-watch.service    # systemd hosts
crontab -l | grep vps-setup                     # cron fallback
journalctl -u vps-firewall-watch.service -n 100 --no-pager
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
# Menu 13 -> Uninstall -> opt in to "remove managed nftables chain/jump"
```

The uninstall path only deletes jump rules carrying the toolkit comment, then flushes/deletes the managed chain. It leaves all other rules untouched. A full ruleset backup is written under `/var/backups/vps-setup/` first.
