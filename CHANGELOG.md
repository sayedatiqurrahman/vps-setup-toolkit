# Changelog

All notable changes to the VPS Setup Toolkit are documented here.

## [1.1.0] - 2026-11-23

### Added

- Firewall-first workflow: selecting any service-install category (1-8) now asks to configure UFW/nftables basics before installation and to choose outbound service access afterwards (one-by-one, standard/reputed preset, all 20 documented categories, or skip).
- Automatic `docker_gwbridge` Traefik ingress rules (`DOKPLOY-INGRESS` and `DOKPLOY-RETURN`) when Docker Engine, Dokploy or Coolify is selected; the watcher restores them after reboots and bridge re-creation.
- Traefik container IP detection from Docker with a configurable `TRAEFIK_IP` fallback.
- `VPS_SETUP_SKIP_FIREWALL=1` to opt out of the automatic firewall steps in `run ... --yes` mode.

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
