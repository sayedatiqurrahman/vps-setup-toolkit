# Installation

## Quick install

On a fresh Linux VPS, run:

```bash
curl -fsSL https://raw.githubusercontent.com/sayedatiqurrahman/vps-setup-toolkit/v1.2.0/install.sh -o install.sh && sudo bash install.sh
```

The command is pinned to release `v1.2.0`. The installer verifies the downloaded archive's SHA-256 against the checksum published in the `checksums` branch before installing anything, so no manual hash setup is needed for production use. A mismatch aborts the install.

The installer copies the toolkit to `/usr/local/lib/vps-setup-toolkit`, creates `/usr/local/sbin/vps-setup`, and opens the interactive menu. No cloning is needed.

Reopen the menu any time with `sudo vps-setup`.

## First-run checklist

1. Keep an existing SSH session open.
2. Select the services you need (items 1-8). The toolkit asks to configure UFW/nftables **before** installing anything.
3. When installation finishes, choose outbound access: one-by-one categories, the standard/reputed preset, all 20 documented categories, or skip.
4. If you selected Docker Engine, Dokploy or Coolify, Docker Swarm is initialized only when inactive, the `docker_gwbridge` Traefik ingress rules are enabled automatically, and the Container Network Doctor is enabled. The watcher keeps the managed rules alive.
5. Use item **9)** to change outbound service ports later; item **10)** only for deliberate host inbound ports. The doctor reuses these allowed ports as its verification targets.
6. Verify with item **12) System Status**, item **14) Container Network Doctor** and an external port check.

## Upgrade / re-run

Re-running the installer updates toolkit files while preserving `/etc/default/vps-setup`, state under `/etc/vps-setup/`, logs, firewall rules and installed packages.

```bash
sudo bash install.sh --install-only
sudo vps-setup run 11 --yes            # optional general repair pass after an upgrade
sudo vps-setup network status          # Docker, Swarm, MTU and managed MSS rules
```

## Uninstall

```bash
sudo vps-setup              # choose 13) Uninstall Toolkit
# or
sudo /usr/local/lib/vps-setup-toolkit/scripts/uninstall.sh
```

The uninstaller offers two options:

1. **Delete only the toolkit** — removes the installed files, watcher, systemd unit and launcher, but keeps `/etc/default/vps-setup`, state, logs and all existing firewall rules. Choose this when you plan to reinstall or restore the toolkit later. Existing rules are no longer reconciled by the watcher until the toolkit is reinstalled.
2. **Delete the toolkit with all configuration** — additionally removes the managed nftables chain/jump, managed MSS rules/state (`VPS-SENTINEL-MSS`), toolkit-managed UFW outbound rules, config, state and logs.

Both options require the typed confirmation `UNINSTALL`. Non-interactive equivalents: `vps-setup uninstall keep-config` and `vps-setup uninstall all` (direct script: `sudo /usr/local/lib/vps-setup-toolkit/scripts/uninstall.sh keep-config|all`). Unrelated firewall rules and installed packages are never removed automatically.

---

## Advanced details

The quick install above is the recommended path for almost everyone. The notes below are for custom or unattended deployments.

### Requirements

- **Any Linux OS.** Debian 12/13 and Ubuntu 22.04/24.04 are the primary test matrix; every other Linux distribution is handled with runtime OS detection and best-effort package-manager support.
- Root access (`sudo`)
- Bash, `curl`, `tar`, `sha256sum` (or `gpg` for signature verification)
- A provider console/rescue access path before changing firewall rules
- Non-Linux systems are not supported: the toolkit manages Linux packages, services and firewalls and will refuse to run there.

### Verified archive install

<details>
<summary>Show SHA-256 / GPG verification steps</summary>

```bash
curl -fsSL https://raw.githubusercontent.com/sayedatiqurrahman/vps-setup-toolkit/v1.2.0/install.sh -o install.sh
chmod 700 install.sh
less install.sh                       # review before running
sudo bash install.sh                  # pinned release: checksum verified automatically
```

For a custom ref or archive, supply the hash explicitly:

```bash
export VPS_SETUP_REF=main
export VPS_SETUP_ARCHIVE_SHA256="<expected sha256>"
sudo bash install.sh
```

Or with a detached signature:

```bash
export VPS_SETUP_SIGNATURE_URL="https://example.invalid/vps-setup-toolkit.tar.gz.asc"
export VPS_SETUP_GPG_KEY_URL="https://example.invalid/signing-key.asc"
sudo bash install.sh
```

The pinned release is verified automatically. Custom refs/archives without a hash or signature are rejected; `--allow-unverified` (or `VPS_SETUP_ALLOW_UNVERIFIED=1`) is for local testing only.

The installer:

1. Downloads the archive from `VPS_SETUP_ARCHIVE_URL` or the configured GitHub repo/ref.
2. Verifies SHA-256 against the published checksum (pinned release), a supplied hash, or a supplied GPG signature; aborts on failure.
3. Copies the toolkit to `/usr/local/lib/vps-setup-toolkit`.
4. Creates `/usr/local/sbin/vps-setup`.
5. Launches the interactive menu (unless `--install-only` is used).

</details>

### Install from a local clone

<details>
<summary>Show clone-based install</summary>

```bash
git clone https://github.com/sayedatiqurrahman/vps-setup-toolkit.git
cd vps-setup-toolkit
sudo bash install.sh --source-dir "$PWD"
```

</details>

### Installer environment variables

| Variable | Purpose | Default |
|---|---|---|
| `VPS_SETUP_REPO_URL` | GitHub repo used to build the codeload URL | `https://github.com/sayedatiqurrahman/vps-setup-toolkit` |
| `VPS_SETUP_REF` | Branch/tag for the archive | `v1.2.0` (pinned release) |
| `VPS_SETUP_ARCHIVE_URL` | Explicit archive URL (any host) | derived from repo URL |
| `VPS_SETUP_ARCHIVE_SHA256` | Expected archive SHA-256 | published checksum for pinned release |
| `VPS_SETUP_SIGNATURE_URL` | Detached GPG signature URL | unset |
| `VPS_SETUP_GPG_KEY_URL` | Signing key URL | unset |
| `VPS_SETUP_ALLOW_UNVERIFIED=1` | Testing only: allow unverified download | unset (verification required) |
| `VPS_SETUP_HOME` | Install directory override | `/usr/local/lib/vps-setup-toolkit` |
| `VPS_SETUP_INSTALL_ONLY=1` | Install without launching menu | unset |
| `ALLOW_UNSUPPORTED_OS=1` | Permit vendor-specific steps on non-primary OS families | unset |
| `VPS_SETUP_SKIP_FIREWALL=1` | Skip automatic firewall steps in `run --yes` | unset |
| `VPS_SETUP_SWARM_ADVERTISE_ADDR` | Advertise address when initializing an inactive Docker Swarm | detected WAN IPv4 |
| `VPS_SETUP_NO_NETWORK_AUTO_REPAIR=1` | Leave network doctor auto-repair disabled on Docker install paths | unset |
| `VPS_SETUP_NETWORK_STATE` | Desired MSS rules file | `/etc/vps-setup/network-mss.rules` |
| `VPS_SETUP_NETWORK_CHANGES` | Network repair change log | `/etc/vps-setup/network-changes.log` |

### OS and package-manager detection

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
