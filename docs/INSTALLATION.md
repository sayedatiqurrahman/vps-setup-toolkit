# Installation

## Requirements

- **Any Linux OS.** Debian 12/13 and Ubuntu 22.04/24.04 are the primary test matrix; every other Linux distribution is handled with runtime OS detection and best-effort package-manager support.
- Root access (`sudo`)
- Bash, `curl`, `tar`, `sha256sum` (or `gpg` for signature verification)
- A provider console/rescue access path before changing firewall rules
- Non-Linux systems are not supported: the toolkit manages Linux packages, services and firewalls and will refuse to run there.

## OS and package-manager detection

On every run the toolkit reads `/etc/os-release` and detects:

| Detected | Values |
|---|---|
| OS family | `debian`, `rhel`, `suse`, `arch`, `alpine`, `unknown` |
| Package manager | `apt`, `dnf`/`yum`/`microdnf`, `zypper`, `pacman`, `apk`, or `none` |
| Init system | `systemd`, `openrc`, `sysv`, or `unknown` |
| Architecture | normalized across dpkg/rpm/os-release (e.g. `x86_64` → `amd64`) |

Unsupported OSes produce an advisory warning and continue with best-effort support. A few vendor-specific steps require an explicit opt-in:

```bash
sudo ALLOW_UNSUPPORTED_OS=1 vps-setup run 3,6 --yes
```

Those steps are Docker's signed apt repository and the NodeSource setup script (which assume Debian/RPM families). PHP extension package names also differ outside Debian; `pkg_install` installs what exists and warns about missing packages instead of aborting.

If no package manager can be detected, the toolkit logs which packages must be installed manually. It never silently pretends an installation succeeded.

## Install from the repository

```bash
curl -fsSL https://raw.githubusercontent.com/sayedatiqurrahman/vps-setup-toolkit/main/install.sh -o install.sh
chmod 700 install.sh
less install.sh                       # review before running
export VPS_SETUP_ARCHIVE_SHA256="<expected sha256>"
sudo bash install.sh
```

The installer:

1. Downloads the archive from `VPS_SETUP_ARCHIVE_URL` or the configured GitHub repo/ref.
2. Verifies SHA-256 and/or GPG signature when variables are supplied.
3. Copies the toolkit to `/usr/local/lib/vps-setup-toolkit`.
4. Creates `/usr/local/sbin/vps-setup`.
5. Launches the interactive menu (unless `--install-only` is used).

Environment variables:

| Variable | Purpose | Default |
|---|---|---|
| `VPS_SETUP_REPO_URL` | GitHub repo used to build the codeload URL | `https://github.com/sayedatiqurrahman/vps-setup-toolkit` |
| `VPS_SETUP_REF` | Branch/tag for the archive | `main` |
| `VPS_SETUP_ARCHIVE_URL` | Explicit archive URL (any host) | derived from repo URL |
| `VPS_SETUP_ARCHIVE_SHA256` | Expected archive SHA-256 | unset (warning) |
| `VPS_SETUP_SIGNATURE_URL` | Detached GPG signature URL | unset |
| `VPS_SETUP_GPG_KEY_URL` | Signing key URL | unset |
| `VPS_SETUP_HOME` | Install directory override | `/usr/local/lib/vps-setup-toolkit` |
| `VPS_SETUP_INSTALL_ONLY=1` | Install without launching menu | unset |
| `ALLOW_UNSUPPORTED_OS=1` | Permit vendor-specific steps on non-primary OS families | unset |

## Install from a local clone

```bash
git clone https://github.com/sayedatiqurrahman/vps-setup-toolkit.git
cd vps-setup-toolkit
sudo bash install.sh --source-dir "$PWD"
```

## Upgrade / re-run

Re-running the installer updates toolkit files while preserving `/etc/default/vps-setup`, state under `/etc/vps-setup/`, logs, firewall rules and installed packages.

```bash
sudo bash install.sh --install-only
sudo vps-setup run 11 --yes    # optional repair pass after an upgrade
```

## Uninstall

```bash
sudo vps-setup              # choose 13) Uninstall Toolkit
# or
sudo /usr/local/lib/vps-setup-toolkit/scripts/uninstall.sh
```

The typed confirmation `UNINSTALL` is required. Removal of the managed nftables chain, UFW egress rules, config, state and logs is opt-in and handled separately. Unrelated firewall rules and installed packages are never removed automatically.

## First-run checklist

1. Keep an existing SSH session open.
2. Select the services you need (items 1-8). The toolkit asks to configure UFW/nftables **before** installing anything.
3. When installation finishes, choose outbound access: one-by-one categories, the standard/reputed preset, all 20 documented categories, or skip.
4. If you selected Docker Engine, Dokploy or Coolify, the `docker_gwbridge` Traefik ingress rules are enabled automatically and kept alive by the watcher.
5. Use item **9)** to change outbound service ports later; item **10)** only for deliberate host inbound ports.
6. Verify with item **12) System Status** and an external port check.
