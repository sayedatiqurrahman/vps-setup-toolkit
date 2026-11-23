# VPS Setup Toolkit

A production-oriented, interactive Bash toolkit for preparing fresh **Debian 12/13** and **Ubuntu 22.04/24.04** VPS servers through one entry point. It installs only what you select, keeps inbound access restrictive by default, and safely coexists with Docker, Dokploy, Coolify, Traefik, UFW and existing nftables rulesets.

> The original specification, [`complete-vps-setup-security-guide.md`](complete-vps-setup-security-guide.md), is kept intact in this repository and remains the primary design reference.

## Features

- **Single installer + unified menu**: `sudo vps-setup` after installation.
- **Multi-select operations**: enter `2,3,4,9` to run several categories in one pass, with a summary and confirmation first.
- **Outbound-only service selector**: 20 documented categories plus custom TCP/UDP ports, duplicate prevention, add/remove handling, and persistent config.
- **Inbound safety**: default public access is SSH (22), HTTP (80), HTTPS (443) and any detected alternate SSH port. Extra inbound ports require a trusted source CIDR or an explicit confirmation. Database, Redis, S3, Docker API and mail ports are never published automatically.
- **Docker-aware firewall**: a dedicated nftables chain with dynamically detected Docker bridges/subnets, a single guarded jump from an existing parent chain, no full-ruleset flush, and a persistent systemd reconciler that recovers after reboots and bridge recreation.
- **Idempotent**: repeated runs do not duplicate UFW rules, nftables jumps, chains, services or configuration.
- **Backups before changes**: configuration files, UFW state and nftables rulesets are backed up before modification.
- **Repair/status/uninstall**: explicit recovery, read-only status, and uninstall that never removes unrelated firewall rules.
- **Root checks, OS/arch detection, strict Bash, validated input, no `eval`, ShellCheck-friendly style.**

## Supported operating systems

| OS | Versions | Notes |
|---|---|---|
| Debian | 12 (bookworm), 13 (trixie) | Primary target of the original guide |
| Ubuntu | 22.04 (jammy), 24.04 (noble) | Supported by the toolkit; other versions require `ALLOW_UNSUPPORTED_OS=1` |

Supported architectures for Docker repositories: `amd64`, `arm64`, `armhf`, `i386`, `riscv64`, `s390x`.

## Installation

### Recommended: verify the installer and archive

```bash
# 1) Download the installer; do not pipe straight into bash.
curl -fsSL https://raw.githubusercontent.com/sayedatiqurrahman/vps-setup-toolkit/main/install.sh -o install.sh

# 2) Review it, then get the expected SHA-256 of the repository archive
#    (publish this hash alongside each release):
export VPS_SETUP_ARCHIVE_SHA256="<sha256-of-archive-tar.gz>"
export VPS_SETUP_REF=main

# 3) Run as root. The installer downloads, verifies, installs and launches the menu.
sudo bash install.sh
```

Alternatively provide a detached signature and public key:

```bash
export VPS_SETUP_SIGNATURE_URL="https://example.invalid/vps-setup-toolkit.tar.gz.asc"
export VPS_SETUP_GPG_KEY_URL="https://example.invalid/signing-key.asc"
sudo bash install.sh
```

If no verification variables are set, the installer warns and proceeds with an unverified archive. For production, always set a hash or signature.

### From a local checkout

```bash
git clone https://github.com/sayedatiqurrahman/vps-setup-toolkit.git
cd vps-setup-toolkit
sudo bash install.sh --source-dir "$PWD"
```

Use `--install-only` to install without opening the menu. The launcher is placed at `/usr/local/sbin/vps-setup`.

### Paths

| Path | Purpose |
|---|---|
| `/usr/local/lib/vps-setup-toolkit` | Installed toolkit files |
| `/usr/local/sbin/vps-setup` | Menu launcher |
| `/etc/default/vps-setup` | Persistent config (same path as the original guide) |
| `/etc/vps-setup/` | State (host inbound rules, last applied nftables rules) |
| `/var/log/vps-setup/` | Setup and watcher logs |
| `/var/backups/vps-setup/` | Timestamped backups of modified files/rulesets |

## Usage

```bash
sudo vps-setup                 # interactive menu
sudo vps-setup run 1,3,9 --yes # non-interactive; --yes is the explicit confirmation
sudo vps-setup status          # read-only status report
sudo vps-setup firewall select # jump straight to the service selector
```

### Terminal menu example

```text
========== VPS SETUP MENU ==========
  1) Base VPS Setup
  2) Node.js and PM2
  3) Docker Engine
  4) Dokploy
  5) Coolify
  6) PHP and Nginx
  7) WordPress Requirements
  8) SSH Security
  9) Firewall and Service Port Manager
 10) Custom Port Configuration
 11) Repair and Recovery
 12) System Status
 13) Uninstall Toolkit
  0) Exit

Enter one number or several separated by commas (example: 2,3,4,9).
Choose an option: 2,3,9
```

Selecting `4` and `5` together (Dokploy and Coolify) requires an extra typed confirmation; they are never installed together automatically.

### Example: allow container egress to remote services

Inside **Firewall and Service Port Manager**, enter:

```text
5,6,18,19,20
```

This permits outbound SMTP 587/465/25, IMAP 993/143, Nixtec MariaDB 23306, Garage S3 24900 and HTTPS 443 from Docker bridges. It does **not** open any inbound port on the VPS.

## Firewall security model

- **Outbound selection** adds explicit `ufw allow out` rules and permits those destination ports in the toolkit-owned `inet cloud_dev vps_docker_forward` nftables chain for detected Docker bridges.
- **Host inbound** rules are managed separately through UFW, optionally restricted to a trusted IPv4/CIDR. Blank source means public and always requires confirmation; sensitive ports require typed authorization.
- **The managed nftables chain** is the only chain this toolkit flushes. It inserts at most one `jump vps_docker_forward` rule (comment `VPS-MANAGED-DOCKER-JUMP`) into an existing parent chain, validates generated rules with `nft -c` before applying them, and never creates a competing table/policy if the documented `inet cloud_dev forward` chain is missing.
- **The watcher** (`vps-firewall-watch.service`) reconciles the chain every 15 seconds using live interface/subnet discovery, so Docker bridge recreation and reboots are handled automatically.

See [`docs/FIREWALL.md`](docs/FIREWALL.md) for the full explanation and rollback steps.

## Supported services / categories

| Menu | Component | Details |
|---|---|---|
| 1 | Base utilities | apt index, core tools, UFW defaults, detected SSH port preserved |
| 2 | Node.js + PM2 | NodeSource 18/20/22 (default 22), npm, optional pnpm, global PM2 |
| 3 | Docker Engine | Docker CE, Compose/Buildx plugins, firewall watcher |
| 4 | Dokploy | Official installer launcher, optional Traefik 80/443 DNAT forwarding |
| 5 | Coolify | Official installer launcher; mutually intentional with Dokploy |
| 6 | PHP + Nginx | Distro PHP-FPM (or chosen X.Y), common extensions, Nginx |
| 7 | WordPress prerequisites | Nginx/PHP and required extensions; WordPress deployed separately |
| 8 | SSH security | Checklist, read-only audit, optional hardening, Fail2ban |
| 9 | Firewall service manager | 20 outbound categories + custom TCP/UDP, add/remove/apply |
| 10 | Custom ports | Trusted-source or explicitly public host inbound UFW rules |
| 11 | Repair and recovery | Config/UFW/nftables/watcher repair, ruleset restore |
| 12 | System status | OS, components, services, UFW, bridges, managed chain, watcher |
| 13 | Uninstall | Removes toolkit with opt-in cleanup of rules/config/logs |

Outbound catalog IDs 1-20 exactly match the original guide (Web/API, DNS, NTP, SSH/Git, SMTP, IMAP, POP3, MySQL, PostgreSQL, MSSQL, Oracle, Redis, MongoDB, S3/MinIO, Elasticsearch, RabbitMQ, MQTT, Nixtec MariaDB, Nixtec Garage/S3, SMS/REST API).

## Troubleshooting

```bash
# Firewall and watcher
sudo ufw status verbose
sudo nft -a list chain inet cloud_dev vps_docker_forward
systemctl status vps-firewall-watch.service
journalctl -u vps-firewall-watch.service -n 100 --no-pager

# Docker bridges and default route
ip -br -4 addr | grep -E 'docker|br-'
ip -4 route show default
```

If `inet cloud_dev forward` is absent, set `NFT_TABLE`/`NFT_PARENT` in `/etc/default/vps-setup` to an existing table/chain after reviewing `nft list ruleset`. The toolkit deliberately will not create a competing firewall policy.

More details: [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md).

## Development and tests

```bash
bash -n $(find . -name '*.sh' -type f)
bash tests/run-tests.sh
```

The tests use stubbed `ip`, `ufw`, `nft` and `systemctl` commands in a temporary directory. They never touch a real firewall. See [`tests/`](tests).

## Contributing

1. Fork the repository and create a feature branch.
2. Keep changes ShellCheck-compatible and idempotent.
3. Add/adjust tests under `tests/` for firewall or validation changes.
4. Never add passwords, API keys or provider secrets to the repository.
5. Open a pull request describing the change and the safety considerations.

## License

MIT — see [`LICENSE`](LICENSE).
