# Troubleshooting

Always keep a provider console or rescue session available before modifying firewall rules.

## Toolkit commands

```bash
sudo vps-setup status
sudo vps-setup firewall status
sudo vps-setup run 11 --yes          # repair pass
sudo /usr/local/lib/vps-setup-toolkit/scripts/firewall.sh nft-reconcile
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
