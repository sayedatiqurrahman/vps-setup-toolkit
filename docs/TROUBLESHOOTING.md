# Troubleshooting

Always keep a provider console or rescue session available before modifying firewall rules.

## Toolkit commands

```bash
sudo vps-setup status
sudo vps-setup firewall status
sudo vps-setup run 11 --yes                 # general repair pass
sudo /usr/local/lib/vps-setup-toolkit/scripts/firewall.sh nft-reconcile
sudo /usr/local/lib/vps-setup-toolkit/scripts/network.sh reconcile
sudo vps-setup network status               # container network doctor
```

## OS detection and unsupported systems

```bash
sudo vps-setup status
cat /etc/os-release
```

The status report prints the detected OS family, package manager, init system and architecture.

- **"No supported package manager detected"**: install the packages listed in `docs/SERVICES.md` manually, or add your distribution's package manager support in `scripts/common.sh`. The toolkit will not guess.
- **"using best-effort ... support"**: the OS is outside the primary Debian/Ubuntu matrix. Normal operations still run; vendor-specific steps (Docker's apt repo, NodeSource) require `sudo ALLOW_UNSUPPORTED_OS=1 vps-setup ...`.
- **"detected '<non-Linux>'"**: the toolkit refuses to run on non-Linux systems because it manages Linux packages, services and firewalls.
- **"UFW is not available"**: base setup skipped host-firewall configuration. Configure your distribution firewall yourself; the toolkit never disables another firewall.

## UFW

```bash
sudo ufw status verbose
sudo ufw show added
```

- Rules with comment `VPS-MANAGED ...` are toolkit-managed. Do not delete them manually unless you also update `/etc/default/vps-setup`.
- If SSH is blocked, use the provider console and check TCP 22 (or your detected alternate port) in `ufw status`.
- Docker-published ports may bypass UFW depending on the Docker firewall backend. Verify externally after every publishing change.

## nftables

```bash
sudo nft list ruleset
sudo nft -a list chain inet cloud_dev forward
sudo nft -a list chain inet cloud_dev vps_docker_forward
```

### Parent chain missing

The toolkit intentionally refuses to create or replace a firewall policy. If `inet cloud_dev forward` does not exist:

1. Review `sudo nft list ruleset`.
2. Set `NFT_TABLE` and `NFT_PARENT` in `/etc/default/vps-setup` to an existing table/chain.
3. Run `sudo vps-setup run 11 --yes` or wait for the watcher.

### Validation errors

`nft -c -f` validation failures are logged to `/var/log/vps-setup/setup.log` and `/var/log/vps-setup/firewall-watch.log`. The generated file is kept temporarily only long enough to apply; run `sudo /usr/local/lib/vps-setup-toolkit/scripts/firewall.sh nft-apply` to regenerate and review the warning. Common causes:

- stale/invalid port values in config (run repair),
- invalid `WAN_IF`, `TRAEFIK_IP` or `NFT_*` identifiers,
- a very old `nft` build without `-c -f` support.

## Docker bridges

```bash
ip -br link | grep -E 'docker|br-'
ip -br -4 addr | grep -E 'docker|br-'
ip -4 route show default
```

The watcher discovers `docker0`, `docker_gwbridge` and `br-<hex>` automatically. After creating a new Docker network, allow up to `WATCH_INTERVAL` seconds (default 15) for rules to appear. If egress still fails, check Docker's own NAT/masquerade rules, DNS inside the container, and any provider-side firewall.

## Container works on host but not inside Docker

Use menu **14) Container Network Doctor** or the CLI. Diagnosis is read-only; no repair is applied unless you explicitly approve it.

```bash
sudo vps-setup network status
sudo vps-setup network containers
sudo vps-setup network diagnose --container <id-or-name> --target api.example.test:443 --protocol https
sudo vps-setup network test --container <id-or-name> --target api.example.test:443
sudo vps-setup network repair --container <id-or-name> --target api.example.test:443 --dry-run
sudo vps-setup network repair --container <id-or-name> --target api.example.test:443 --apply
sudo vps-setup network verify --container <id-or-name> --target api.example.test:443 --fresh-connections 5
sudo vps-setup network rollback [change-id]
sudo vps-setup network watch 1
```

The doctor runs the same DNS/TCP/TLS/application probe from the host and from the selected container, then reports a root cause:

| Root cause | Meaning | Automatic repair? |
|---|---|---|
| `NONE` | No container-specific failure | No change |
| `DNS` | Host resolves, container does not | No; check Docker DNS/upstream resolvers |
| `ROUTING_OR_FIREWALL` | DNS works, container TCP fails | No; inspect DOCKER-USER, nftables forward chains, MASQUERADE |
| `MTU_MSS` | TCP works, TLS/HTTPS stalls, MTU evidence supports it | **Yes**, scoped MSS clamp with approval |
| `TLS_OR_PROXY` | TCP works, TLS fails without MTU evidence | No; check CA/time/SNI/proxy, never disable verification |
| `APPLICATION_AUTH` / `APPLICATION_PROTOCOL` | TCP/TLS works, application rejects the request | No; not a firewall issue |
| `DESTINATION_OR_HOST` | The VPS itself fails the test | No; fix host connectivity first |

Target selection is dynamic: `NETWORK_TARGET_PORT` in `/etc/default/vps-setup` wins; otherwise one allowed outbound TCP port is auto-selected, interactive mode offers a choice when several are allowed, and non-interactive runs use the first allowed port deterministically. `NETWORK_TARGET_HOST` supplies the hostname when `--target` is omitted. Use `--protocol http|https|smtp|smtps|imap|imaps|mqtt|mqtts|dns|...` for non-web services; STARTTLS/plain profiles are verified at TCP level instead of being reported as false TLS failures.

When `MTU_MSS` is diagnosed, `--dry-run` prints the exact plan. `--apply` requires typing `APPLY-NETWORK-REPAIR`, backs up the mangle table, creates only `VPS-SENTINEL-MSS` with one bridge→WAN clamp rule per discovered Docker bridge and one commented `FORWARD` jump, then runs fresh verification. Failed verification automatically rolls back. Changes are logged in `/etc/vps-setup/network-changes.log`; desired state is `/etc/vps-setup/network-mss.rules`.

```bash
sudo iptables -w -t mangle -S VPS-SENTINEL-MSS
sudo iptables -w -t mangle -S FORWARD | grep VPS-SENTINEL-JUMP
sudo vps-setup network mss-status
sudo vps-setup network rollback          # immediate rollback to pre-repair state
```

Docker Swarm is initialized on Docker/Dokploy/Coolify install paths only when the node is `inactive`. `active` nodes are left untouched; `pending`, `locked` and `error` states are reported for manual handling. Use `VPS_SETUP_SWARM_ADVERTISE_ADDR` to control the advertise address.

Proxy variables are shown with credentials redacted. The doctor never installs tools inside application containers, never uses a digest-less diagnostic sidecar by default, and never disables TLS verification.

## Watcher

On systemd hosts:

```bash
systemctl status vps-firewall-watch.service
journalctl -u vps-firewall-watch.service -n 100 --no-pager
sudo systemctl restart vps-firewall-watch.service
```

On non-systemd hosts the toolkit installs a cron fallback instead:

```bash
crontab -l | grep vps-setup
tail -n 50 /var/log/vps-setup/firewall-watch.log
```

If neither supervisor is present, the watcher binary and unit are installed but nothing runs them; configure a supervisor or run `firewall.sh nft-reconcile` manually after Docker network changes.

If the unit/cron entry is missing, run menu item **11) Repair and Recovery** or `sudo /usr/local/lib/vps-setup-toolkit/scripts/firewall.sh watcher`.

## SSH safety

- Keep a second session open before changing `sshd_config`.
- Validate with `sudo sshd -t` and reload with `sudo systemctl reload ssh` (or `sshd`).
- The toolkit never changes the SSH port automatically. If you change it manually, add the matching UFW rule first (menu 10).

## Logs and backups

```bash
ls -l /var/log/vps-setup/
ls -lR /var/backups/vps-setup/
```

Configuration files, sshd config, apt sources, wrapper binaries and nftables/UFW snapshots are backed up before modification. Restore carefully and verify with the validation commands above.
