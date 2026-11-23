```text
╔═════════════════════════════════════════════════════════════════════════╗
║  __     ______  ____    ____  _____ _   _ _____ ___ _   _ _____ _       ║
║  \ \   / /  _ \/ ___|  / ___|| ____| \ | |_   _|_ _| \ | | ____| |      ║
║   \ \ / /| |_) \___ \  \___ \|  _| |  \| | | |  | ||  \| |  _| | |      ║
║    \ V / |  __/ ___) |  ___) | |___| |\  | | |  | || |\  | |___| |___   ║
║     \_/  |_|   |____/  |____/|_____|_| \_| |_| |___|_| \_|_____|_____|  ║
╚═════════════════════════════════════════════════════════════════════════╝
```

# VPS SENTINEL

**VPS Setup Toolkit** — one command to prepare, secure and maintain a Linux VPS.

> Powered by **Programming Light** · Developed by **Sayed Atiqur Rahman**

VPS Sentinel installs only what you select, keeps inbound access restrictive by default, and safely coexists with Docker, Dokploy, Coolify, Traefik, UFW and existing nftables rulesets. It is open source under the MIT license.

> The original specification, [`complete-vps-setup-security-guide.md`](complete-vps-setup-security-guide.md), is kept intact and remains the primary design reference.

## Table of contents

- [Quick installation](#quick-installation)
- [Usage](#usage)
- [How it works](#how-it-works)
  - [Firewall-first workflow](#firewall-first-workflow)
  - [Automatic Docker / Traefik ingress](#automatic-docker--traefik-ingress)
  - [Firewall security model](#firewall-security-model)
- [Menu options](#menu-options)
- [Configuration paths](#configuration-paths)
- [Troubleshooting](#troubleshooting)
- [Development and tests](#development-and-tests)
- [Contributing](#contributing)
- [License](#license)
- [Appendix](#appendix)
  - [Alternative installation methods](#alternative-installation-methods)
  - [Supported systems](#supported-systems)

## Quick installation

Run this on your VPS as root (or with `sudo` available). No cloning required:

```bash
curl -fsSL https://raw.githubusercontent.com/sayedatiqurrahman/vps-setup-toolkit/v1.1.0/install.sh -o install.sh && sudo bash install.sh
```

That is it. The command is pinned to release `v1.1.0`: the installer downloads that release's archive and **automatically verifies its SHA-256** against the checksum published in the `checksums` branch. No warnings, no manual hash setup — safe for production.

The installer places the toolkit in `/usr/local/lib/vps-setup-toolkit`, creates the `vps-setup` launcher, and opens the interactive menu.

Start it again any time with:

```bash
sudo vps-setup
```

> On a fresh VPS, choose **1) Base VPS Setup** first. The toolkit will ask you to configure the firewall before it installs anything else.

## Usage

```bash
sudo vps-setup                       # interactive menu
sudo vps-setup run 1,3,9 --yes       # non-interactive; --yes is explicit confirmation
sudo vps-setup status                # read-only status report
sudo vps-setup firewall select       # jump straight to the outbound service selector
```

Enter several category numbers at the prompt, separated by commas — for example `2,3,4,9`. You always see a summary and confirm before anything is installed.

## How it works

### Firewall-first workflow

Any selection that installs or configures a service (menu items **1-8**) follows this order:

1. **Before installation** — you are asked to configure UFW/nftables basics: default-deny inbound, default-allow outbound, baseline SSH/HTTP/HTTPS rules, the managed nftables chain and the persistent watcher. This happens first so applications do not fail later because of missing database, mail or Docker rules.
2. **Services are installed** in the order you selected.
3. **After installation** — you are asked again to configure UFW/nftables and choose outbound service access:
   - `1` — choose services **one by one** (SMTP, IMAP, MySQL, Redis, S3, ...), with a `y/N` prompt per category;
   - `2` — allow all **standard/reputed** services (Web/API, DNS, NTP, SSH/Git, SMTP, IMAP, POP3, SMS API);
   - `3` — allow all 20 documented categories (still outbound-only);
   - `0` — skip.

`vps-setup run <ids> --yes` applies the safe defaults automatically. Set `VPS_SETUP_SKIP_FIREWALL=1` to opt out of both automatic steps.

### Automatic Docker / Traefik ingress

Selecting Docker Engine, Dokploy or Coolify (menu items **3, 4, 5**) enables managed ingress rules for `docker_gwbridge` automatically. The watcher keeps them live after reboots and bridge re-creation:

- `DOKPLOY-INGRESS` — public TCP 80/443, already DNATed, WAN → `docker_gwbridge` → Traefik IPv4.
- `DOKPLOY-RETURN` — established/related traffic back from Traefik to the WAN interface.

The Traefik address is detected from the running container when possible; otherwise `TRAEFIK_IP` from `/etc/default/vps-setup` is used (default `10.0.2.2`). You never need to insert these rules by hand.

### Firewall security model

- **Outbound selection** adds explicit `ufw allow out` rules and permits those destination ports in the toolkit-owned `inet cloud_dev vps_docker_forward` nftables chain for detected Docker bridges.
- **Host inbound** rules are managed separately through UFW, optionally restricted to a trusted IPv4/CIDR. Blank source means public and always requires confirmation; sensitive ports require typed authorization.
- **The managed nftables chain** is the only chain this toolkit flushes. It inserts at most one `jump vps_docker_forward` rule (comment `VPS-MANAGED-DOCKER-JUMP`) into an existing parent chain, validates generated rules with `nft -c` before applying them, and never creates a competing table/policy if the documented `inet cloud_dev forward` chain is missing.
- **The watcher** reconciles the chain every 15 seconds using live interface/subnet discovery. It runs as `vps-firewall-watch.service` under systemd, or as a managed cron entry on non-systemd Linux systems.

Full details: [`docs/FIREWALL.md`](docs/FIREWALL.md).

## Menu options

| Menu | Component | Details |
|---|---|---|
| 1 | Base utilities | Package index for the detected manager, core tools, UFW defaults, detected SSH port preserved |
| 2 | Node.js + PM2 | NodeSource 18/20/22 (default 22), npm, optional pnpm, global PM2 |
| 3 | Docker Engine | Docker CE, Compose/Buildx plugins, firewall watcher, automatic Traefik ingress |
| 4 | Dokploy | Official installer launcher, managed Traefik 80/443 ingress |
| 5 | Coolify | Official installer launcher; mutually intentional with Dokploy |
| 6 | PHP + Nginx | Distro PHP-FPM (or chosen X.Y), common extensions, Nginx |
| 7 | WordPress prerequisites | Nginx/PHP and required extensions; WordPress deployed separately |
| 8 | SSH security | Checklist, read-only audit, optional hardening, Fail2ban |
| 9 | Firewall service manager | 20 outbound categories + custom TCP/UDP, add/remove/apply |
| 10 | Custom ports | Trusted-source or explicitly public host inbound UFW rules |
| 11 | Repair and recovery | Config/UFW/nftables/watcher repair, ruleset restore |
| 12 | System status | OS, components, services, UFW, bridges, managed chain, watcher |
| 13 | Uninstall | Removes toolkit with opt-in cleanup of rules/config/logs |

Dokploy and Coolify selected together require an extra typed confirmation; they are never installed together automatically.

## Configuration paths

| Path | Purpose |
|---|---|
| `/usr/local/lib/vps-setup-toolkit` | Installed toolkit files |
| `/usr/local/sbin/vps-setup` | Menu launcher |
| `/etc/default/vps-setup` | Persistent config (same path as the original guide) |
| `/etc/vps-setup/` | State (host inbound rules, last applied nftables rules) |
| `/var/log/vps-setup/` | Setup and watcher logs |
| `/var/backups/vps-setup/` | Timestamped backups of modified files/rulesets |

## Troubleshooting

```bash
sudo vps-setup status
sudo ufw status verbose
sudo nft -a list chain inet cloud_dev vps_docker_forward
systemctl status vps-firewall-watch.service          # systemd hosts
crontab -l | grep vps-setup                           # cron fallback
journalctl -u vps-firewall-watch.service -n 100 --no-pager
ip -br -4 addr | grep -E 'docker|br-'
```

If `inet cloud_dev forward` is absent, set `NFT_TABLE`/`NFT_PARENT` in `/etc/default/vps-setup` to an existing table/chain after reviewing `nft list ruleset`. The toolkit deliberately will not create a competing firewall policy.

More details: [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md).

## Development and tests

```bash
bash -n $(find . -name '*.sh' -type f)
bash tests/run-tests.sh
```

The suite covers validation, firewall behaviour (stubbed `ip`/`ufw`/`nft`/`systemctl`) and OS/package-manager detection via `/etc/os-release` fixtures. It never touches a real firewall or installs real packages. See [`tests/`](tests).

## Contributing

VPS Sentinel is open source and contributions are welcome — bug reports, docs fixes, new service catalog entries and tests are all valuable. See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the full guide.

## License

MIT — see [`LICENSE`](LICENSE).

---

## Appendix

The sections below are for advanced setups. The [quick installation](#quick-installation) above is all most users need.

### Alternative installation methods

<details>
<summary>Install from a local git clone</summary>

```bash
git clone https://github.com/sayedatiqurrahman/vps-setup-toolkit.git
cd vps-setup-toolkit
sudo bash install.sh --source-dir "$PWD"
```

Add `--install-only` to install without opening the menu.

</details>

<details>
<summary>Archive verification (SHA-256 or GPG)</summary>

The pinned [quick installation](#quick-installation) verifies SHA-256 automatically. For a custom ref or archive, supply the hash explicitly:

```bash
curl -fsSL https://raw.githubusercontent.com/sayedatiqurrahman/vps-setup-toolkit/v1.1.0/install.sh -o install.sh
export VPS_SETUP_REF=main
export VPS_SETUP_ARCHIVE_SHA256="<sha256-of-archive-tar.gz>"
sudo bash install.sh
```

Or with a detached signature:

```bash
export VPS_SETUP_SIGNATURE_URL="https://example.invalid/vps-setup-toolkit.tar.gz.asc"
export VPS_SETUP_GPG_KEY_URL="https://example.invalid/signing-key.asc"
sudo bash install.sh
```

A custom ref/archive without a supplied hash or signature is rejected by default. For local testing only, `--allow-unverified` or `VPS_SETUP_ALLOW_UNVERIFIED=1` permits an unverified download and prints a warning.

</details>

<details>
<summary>Installer environment variables</summary>

| Variable | Purpose | Default |
|---|---|---|
| `VPS_SETUP_REPO_URL` | GitHub repo used to build the codeload URL | `https://github.com/sayedatiqurrahman/vps-setup-toolkit` |
| `VPS_SETUP_REF` | Branch/tag for the archive | `v1.1.0` (pinned release) |
| `VPS_SETUP_ARCHIVE_URL` | Explicit archive URL (any host) | derived from repo URL |
| `VPS_SETUP_ARCHIVE_SHA256` | Expected archive SHA-256 | published checksum for pinned release |
| `VPS_SETUP_SIGNATURE_URL` | Detached GPG signature URL | unset |
| `VPS_SETUP_GPG_KEY_URL` | Signing key URL | unset |
| `VPS_SETUP_ALLOW_UNVERIFIED=1` | Testing only: allow unverified download | unset (verification required) |
| `VPS_SETUP_HOME` | Install directory override | `/usr/local/lib/vps-setup-toolkit` |
| `VPS_SETUP_INSTALL_ONLY=1` | Install without launching menu | unset |
| `ALLOW_UNSUPPORTED_OS=1` | Permit vendor-specific steps on non-primary OS families | unset |
| `VPS_SETUP_SKIP_FIREWALL=1` | Skip automatic firewall steps in `run --yes` | unset |

</details>

### Supported systems

**Any Linux OS can run VPS Sentinel.** It reads `/etc/os-release`, detects the OS family, package manager and init system at runtime, and degrades gracefully outside the Debian/Ubuntu test matrix.

| OS family | Package manager | Status |
|---|---|---|
| Debian 12/13, Ubuntu 22.04/24.04 | apt | Primary test matrix |
| Other Debian derivatives | apt | Best-effort apt path |
| RHEL family (RHEL, CentOS, Rocky, AlmaLinux, Fedora, Amazon Linux) | dnf/yum | Best-effort; vendor-specific steps need `ALLOW_UNSUPPORTED_OS=1` |
| openSUSE / SLES | zypper | Best-effort |
| Arch / Manjaro | pacman | Best-effort |
| Alpine | apk | Best-effort |
| Unrecognized Linux | auto-detected | Best-effort; missing packages are reported |

Non-Linux systems are refused. Without systemd, the watcher falls back to a managed cron entry. Docker's signed repositories support `amd64`, `arm64`, `armhf`, `i386`, `riscv64` and `s390x`; other architectures use distribution packages.

More detail: [`docs/INSTALLATION.md`](docs/INSTALLATION.md).
