# VPS Setup Toolkit

A production-oriented, interactive Bash toolkit for preparing a fresh **Linux** VPS through one entry point — on any Linux distribution. The original guide's Debian/Ubuntu path is the best-tested one, but the toolkit detects the OS family, package manager and init system at runtime and degrades gracefully elsewhere. It installs only what you select, keeps inbound access restrictive by default, and safely coexists with Docker, Dokploy, Coolify, Traefik, UFW and existing nftables rulesets.

> The original specification, [`complete-vps-setup-security-guide.md`](complete-vps-setup-security-guide.md), is kept intact in this repository and remains the primary design reference.

## Features

- **Single installer + unified menu**: `sudo vps-setup` after installation.
- **Multi-select operations**: enter `2,3,4,9` to run several categories in one pass, with a summary and confirmation first.
- **Outbound-only service selector**: 20 documented categories plus custom TCP/UDP ports, duplicate prevention, add/remove handling, and persistent config.
- **Inbound safety**: default public access is SSH (22), HTTP (80), HTTPS (443) and any detected alternate SSH port. Extra inbound ports require a trusted source CIDR or an explicit confirmation. Database, Redis, S3, Docker API and mail ports are never published automatically.
- **Docker-aware firewall**: a dedicated nftables chain with dynamically detected Docker bridges/subnets, a single guarded jump from an existing parent chain, no full-ruleset flush, and a persistent reconciler (systemd unit, with a cron fallback) that recovers after reboots and bridge recreation.
- **Idempotent**: repeated runs do not duplicate UFW rules, nftables jumps, chains, services or configuration.
- **Backups before changes**: configuration files, UFW state and nftables rulesets are backed up before modification.
- **Repair/status/uninstall**: explicit recovery, read-only status, and uninstall that never removes unrelated firewall rules.
- **OS-agnostic where possible**: runtime detection of OS family, package manager and init system, with best-effort support for apt, dnf/yum, apk, pacman and zypper; non-Linux systems are refused.
- **Root checks, arch detection, strict Bash, validated input, no `eval`, ShellCheck-clean style.**

## Supported operating systems

**Any Linux OS can run this toolkit.** On each run it reads `/etc/os-release`, detects the OS family (`debian`, `rhel`, `suse`, `arch`, `alpine`, or `unknown`), selects a package manager (`apt`, `dnf`/`yum`, `zypper`, `pacman`, `apk`), and detects the init system (`systemd`, `openrc`, `sysv`, or none).

| OS family | Package manager | Status |
|---|---|---|
| Debian 12/13, Ubuntu 22.04/24.04 | apt | Fully supported — primary test matrix from the original guide |
| Other Debian derivatives (Linux Mint, Pop!_OS, Raspberry Pi OS, etc.) | apt | Uses the apt path; advisory compatibility warning |
| RHEL family (RHEL, CentOS Stream, Rocky, AlmaLinux, Fedora, Amazon Linux) | dnf/yum | Best-effort distro packages; Docker/NodeSource repo steps require `ALLOW_UNSUPPORTED_OS=1` |
| openSUSE / SLES | zypper | Best-effort distro packages |
| Arch / Manjaro | pacman | Best-effort distro packages |
| Alpine | apk | Best-effort distro packages |
| Unrecognized Linux | auto-detected from available tools | Best-effort; missing packages are reported, not silently ignored |

Rules for non-primary systems:

- Non-Linux systems (e.g. macOS, BSD, Windows) are **refused**: the toolkit manages Linux packages and firewalls.
- Unsupported OSes are **not** hard-blocked. They produce a warning and set `OS_SUPPORTED=0`; ordinary operations continue with best-effort package-manager support.
- Steps that assume a specific vendor layout (Docker's signed apt repo, NodeSource repo scripts, distro-specific PHP extension names) require an explicit opt-in:

  ```bash
  sudo ALLOW_UNSUPPORTED_OS=1 vps-setup run 3,6 --yes
  ```

- If no package manager can be detected, the toolkit reports which packages must be installed manually rather than guessing.
- UFW/nftables are used where available. On a firewall stack the toolkit does not manage (e.g. firewalld-only hosts), it warns and leaves the host firewall to you — it never disables another firewall.
- Without systemd, the watcher falls back to a managed cron entry (one reconcile per minute). Without both systemd and cron, it installs the watcher binary and unit but warns that you must supply a supervisor.

Supported architectures for Docker's signed repositories: `amd64`, `arm64`, `armhf`, `i386`, `riscv64`, `s390x`. Other architectures use best-effort distribution packages.

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

### Firewall-first workflow

Any selection that installs or configures a service (menu items **1-8**) now follows this order:

1. **Before installation** — you are asked to configure UFW/nftables basics: default-deny inbound, default-allow outbound, baseline SSH/HTTP/HTTPS rules, the managed nftables chain, and the persistent watcher. This is done first so applications do not fail later because of missing database/mail/Docker rules.
2. **Services are installed** in the order you selected.
3. **After installation** — you are asked again to configure UFW/nftables and to choose outbound service access:
   - `1` — choose services **one by one** (SMTP, IMAP, MySQL, Redis, S3, ...), with a `y/N` prompt per category;
   - `2` — allow all **standard/reputed** services (Web/API, DNS, NTP, SSH/Git, SMTP, IMAP, POP3, SMS API);
   - `3` — allow all 20 documented categories (still outbound-only);
   - `0` — skip.

`vps-setup run <ids> --yes` applies the safe defaults automatically (firewall basics first, standard preset afterwards). Set `VPS_SETUP_SKIP_FIREWALL=1` to opt out of both automatic steps.

### Docker / Traefik ingress is automatic

When you select Docker Engine, Dokploy or Coolify (menu items **3, 4, 5**), the toolkit enables managed ingress rules for `docker_gwbridge` automatically. The watcher keeps them live after reboots and bridge recreation:

- `DOKPLOY-INGRESS` — public TCP 80/443, already DNATed, WAN → `docker_gwbridge` → Traefik IPv4.
- `DOKPLOY-RETURN` — established/related traffic back from Traefik to the WAN interface.

The Traefik address is detected from the running container when possible, otherwise `TRAEFIK_IP` from `/etc/default/vps-setup` is used (default `10.0.2.2`). You never need to insert these rules by hand.

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
- **The watcher** reconciles the chain every 15 seconds using live interface/subnet discovery, so Docker bridge recreation and reboots are handled automatically. It runs as `vps-firewall-watch.service` under systemd, or as a managed cron entry on non-systemd Linux systems. The managed chain also carries the `DOKPLOY-INGRESS` / `DOKPLOY-RETURN` rules for Traefik on `docker_gwbridge`.

See [`docs/FIREWALL.md`](docs/FIREWALL.md) for the full explanation and rollback steps.

## Supported services / categories

| Menu | Component | Details |
|---|---|---|
| 1 | Base utilities | Package index for the detected manager, core tools, UFW defaults, detected SSH port preserved |
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
systemctl status vps-firewall-watch.service          # systemd hosts
crontab -l | grep vps-setup                           # cron fallback
journalctl -u vps-firewall-watch.service -n 100 --no-pager

# Docker bridges and default route
ip -br -4 addr | grep -E 'docker|br-'
ip -4 route show default

# OS detection used by the toolkit
sudo vps-setup status        # prints OS family, package manager and init system
```

If `inet cloud_dev forward` is absent, set `NFT_TABLE`/`NFT_PARENT` in `/etc/default/vps-setup` to an existing table/chain after reviewing `nft list ruleset`. The toolkit deliberately will not create a competing firewall policy.

More details: [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md).

## Development and tests

```bash
bash -n $(find . -name '*.sh' -type f)
bash tests/run-tests.sh
```

The suite covers validation, firewall behaviour (stubbed `ip`/`ufw`/`nft`/`systemctl`) and OS/package-manager detection via `/etc/os-release` fixtures. They never touch a real firewall or install real packages. See [`tests/`](tests).

## Contributing

1. Fork the repository and create a feature branch.
2. Keep changes ShellCheck-compatible and idempotent.
3. Add/adjust tests under `tests/` for firewall or validation changes.
4. Never add passwords, API keys or provider secrets to the repository.
5. Open a pull request describing the change and the safety considerations.

## License

MIT — see [`LICENSE`](LICENSE).
