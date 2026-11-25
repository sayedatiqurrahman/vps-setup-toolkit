# Changelog

All notable changes to the VPS Setup Toolkit are documented here.

## [1.3.0] - 2026-11-25

### Added

- Unified Service Access as main menu 15 and `vps-setup service ...`: 58 outbound service definitions, presets, custom service IDs, IPv6 egress, audit/repair and host/container connectivity tests.
- DNS & Domain Routing as main menu 16 and `vps-setup dns ...`: Cloudflare A/AAAA/CNAME upsert/delete, root-only token storage, Cloudflare IP range refresh, Cloudflare origin UFW allow rules, domain state and Traefik/Docker label guidance. Provider-agnostic state is kept for other DNS providers.
- Persistent DNS state at `/etc/vps-setup/dns-domains.rules`, `/etc/vps-setup/cloudflare.token` (0600), `/etc/vps-setup/cloudflare-ips.json` and `/etc/vps-setup/cloudflare-origin.rules`.
- `AGENT.md` release handoff with exact safety invariants and publication commands.

### Fixed

- Docker egress rules now accept `ct state { new, established, related }`, so TLS handshakes from containers are not dropped after the initial packet (reported with SMTP 587 / IMAPS 993).
- The toolkit-owned jump is moved to the first parent-chain rule, preventing unrelated drops or verdict-returning chains from making managed rules unreachable.
- `nft -c -f` parser errors are displayed instead of suppressed; rejected rulesets are preserved at `/etc/vps-setup/nft-last-failed.rules` and parser output at `/etc/vps-setup/nft-validation.log`.
- Duplicate jump cleanup no longer touches unrelated rules; failed configuration changes roll back to the last working state.

### Safety

- No full ruleset flush, permissive policy change, physical MTU change, Swarm recreation or TLS verification bypass. No database, Redis, mail, Docker API or blanket container-port exposure.

## [1.2.0] - 2026-11-25

### Added

- Sentinel Container Network Doctor integrated into the toolkit: Docker/Swarm/network inventory, host-versus-container DNS/TCP/TLS/application probes, proxy redaction, read-only diagnosis and root-cause reporting.
- Safe evidence-based MSS repair with a toolkit-owned `VPS-SENTINEL-MSS` iptables mangle chain, scoped bridge-to-WAN rules, mangle backup, dry-run, typed approval, fresh-connection verification, logging and one-command rollback.
- Dynamic verification targets derived from allowed outbound TCP ports: explicit `NETWORK_TARGET_PORT` wins, one port is auto-selected, multiple ports prompt interactively, and non-interactive runs use the first allowed port deterministically.
- CLI `vps-setup network status|containers|diagnose|test|repair|verify|rollback|watch` plus menu 14 with the same actions.
- Docker Swarm initialization on every Docker-related install path, only for inactive nodes; active Swarms are left untouched and locked/error/pending states are reported.
- Network reconciliation in the firewall watcher/cron fallback and automatic enablement after Docker Engine, Dokploy or Coolify installation.
- Container network doctor test suite with stubbed Docker, iptables and probe commands; network state and change-log cleanup in uninstall `all` mode.

### Safety

- No full ruleset flush, firewall policy change, physical MTU change, Swarm recreation, database/Docker API exposure, TLS verification bypass or package installation inside application containers.

## [1.1.5] - 2026-11-23

### Removed

- Remaining provider-specific branding from the service presets and setup guide.

## [1.1.4] - 2026-11-23

### Removed

- The collaboration credit from the README and startup banner.

## [1.1.3] - 2026-11-23

### Changed

- Credits temporarily listed an additional collaborating company alongside Programming Light in the README and the toolkit's startup banner.

## [1.1.2] - 2026-11-23

### Added

- Two explicit uninstall modes: **toolkit only** (keeps configuration, state, logs and firewall rules) and **toolkit with all configuration** (also removes managed firewall rules, config, state and logs). Available in menu 13, via `vps-setup uninstall keep-config|all`, and in the standalone uninstaller.
- The VPS SENTINEL ASCII banner now appears first whenever the toolkit starts, including the first launch from the installer.
- Uninstall mode tests (`tests/test-uninstall.sh`) with stubbed firewall commands.

## [1.1.1] - 2026-11-23

### Added

- Production-safe default installation: the installer is pinned to release `v1.1.1` and automatically verifies the downloaded archive against a SHA-256 checksum published in the separate `checksums` branch. Custom refs/archives without a hash or signature are rejected; `--allow-unverified` is available for local testing only.
- Installer bootstrap regression tests (`tests/test-installer.sh`) covering remote install, published-checksum verification, checksum mismatch rejection and incomplete-archive rejection.

### Fixed

- Version tags are requested from `refs/tags` directly, so the pinned release download no longer logs a 404 retry.

## [1.1.0] - 2026-11-23

### Added

- Firewall-first workflow: selecting any service-install category (1-8) now asks to configure UFW/nftables basics before installation and to choose outbound service access afterwards (one-by-one, standard/reputed preset, all 20 documented categories, or skip).
- Automatic `docker_gwbridge` Traefik ingress rules (`DOKPLOY-INGRESS` and `DOKPLOY-RETURN`) when Docker Engine, Dokploy or Coolify is selected; the watcher restores them after reboots and bridge re-creation.
- Traefik container IP detection from Docker with a configurable `TRAEFIK_IP` fallback.
- `VPS_SETUP_SKIP_FIREWALL=1` to opt out of the automatic firewall steps in `run ... --yes` mode.
- `CONTRIBUTING.md` with open-source contribution opportunities, development workflow and safety guidelines.
- Branded classic figlet-style ASCII banner for **VPS Sentinel** (powered by Programming Light, developed by Sayed Atiqur Rahman) and a clickable table of contents in the README.
- README restructured around the single-command installation; advanced alternatives and supported systems moved to the appendix.

### Fixed

- Remote installation no longer reports success without copying any files: status output from `bootstrap_download` is no longer captured into `SOURCE_ROOT`, and the installer now fails loudly when required files (`menu.sh`, `install.sh`, `scripts/common.sh`, `config/services.conf`) are missing from the install directory.
- `menu.sh` no longer builds module paths as `scripts/scripts/<module>.sh`; it now sources each module directly from `SCRIPT_DIR`, so the menu starts after a fresh remote install.


### Removed

- `AGENT.md` from the repository.

## [1.0.0] - 2026-11-23

### Added

- Single entry point (`install.sh`) with local and remote bootstrap modes, optional SHA-256 and GPG verification of downloaded archives, and installation into `/usr/local/lib/vps-setup-toolkit`.
- Unified interactive menu (`menu.sh`) with 13 categories, comma-separated multi-selection (for example `2,3,4,9`), summary and confirmation before changes, and a non-interactive `run` mode that requires `--yes`.
- Persistent configuration at `/etc/default/vps-setup` (compatible with the original setup guide) plus state under `/etc/vps-setup/` and logs under `/var/log/vps-setup/`.
- Outbound service catalog (`config/services.conf`) with the 20 categories from the original guide, custom TCP/UDP ports, duplicate prevention, and add/remove selection handling.
- UFW management with idempotent managed egress rules, default SSH/HTTP/HTTPS inbound policy, restricted or explicitly confirmed public host inbound ports, and tracking/removal of toolkit-managed rules.
- Dedicated nftables chain (`vps_docker_forward` by default) with dynamic Docker bridge/subnet detection, a single guarded jump from an existing forward chain, atomic validation with `nft -c`, and no full-ruleset flush.
- Persistent watcher that reconciles managed nftables rules after reboot, bridge recreation, or subnet changes: a systemd unit on systemd hosts and a managed cron entry as a portable fallback.
- Installation modules for base utilities, Node.js (18/20/22), npm/pnpm, PM2, Docker Engine/Compose, Dokploy, Coolify, Nginx, PHP-FPM, WordPress prerequisites, Fail2ban, and SSH audit/hardening suggestions.
- Repair/recovery, system status, and uninstall modules with explicit confirmations and no automatic removal of unrelated firewall rules.
- Cross-OS support: runtime detection of OS family, package manager (apt/dnf/yum/apk/pacman/zypper) and init system (systemd/openrc/sysv), best-effort support for any Linux distribution, `ALLOW_UNSUPPORTED_OS=1` for vendor-specific steps, and a clear refusal on non-Linux hosts.
- Documentation (`README.md`, `docs/*.md`) and non-destructive stubbed test suites for validation, service selection, UFW/nftables rule generation, bridge detection, OS detection, and idempotency.

### Safety notes

- No database, Redis, S3, Docker API, or mail port is opened inbound by default.
- Dokploy and Coolify are never installed together automatically; the menu warns and requires a separate decision.
- The toolkit never creates a competing nftables policy when the documented existing `inet cloud_dev forward` chain is absent.
