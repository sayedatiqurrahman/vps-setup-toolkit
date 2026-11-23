# Changelog

All notable changes to the VPS Setup Toolkit are documented here.

## [1.0.0] - 2026-11-23

### Added

- Single entry point (`install.sh`) with local and remote bootstrap modes, optional SHA-256 and GPG verification of downloaded archives, and installation into `/usr/local/lib/vps-setup-toolkit`.
- Unified interactive menu (`menu.sh`) with 13 categories, comma-separated multi-selection (for example `2,3,4,9`), summary and confirmation before changes, and a non-interactive `run` mode that requires `--yes`.
- Persistent configuration at `/etc/default/vps-setup` (compatible with the original setup guide) plus state under `/etc/vps-setup/` and logs under `/var/log/vps-setup/`.
- Outbound service catalog (`config/services.conf`) with the 20 categories from the original guide, custom TCP/UDP ports, duplicate prevention, and add/remove selection handling.
- UFW management with idempotent managed egress rules, default SSH/HTTP/HTTPS inbound policy, restricted or explicitly confirmed public host inbound ports, and tracking/removal of toolkit-managed rules.
- Dedicated nftables chain (`vps_docker_forward` by default) with dynamic Docker bridge/subnet detection, a single guarded jump from an existing forward chain, atomic validation with `nft -c`, and no full-ruleset flush.
- Persistent systemd watcher that reconciles managed nftables rules after reboot, bridge recreation, or subnet changes.
- Installation modules for base utilities, Node.js (18/20/22), npm/pnpm, PM2, Docker Engine/Compose, Dokploy, Coolify, Nginx, PHP-FPM, WordPress prerequisites, Fail2ban, and SSH audit/hardening suggestions.
- Repair/recovery, system status, and uninstall modules with explicit confirmations and no automatic removal of unrelated firewall rules.
- Documentation (`README.md`, `docs/*.md`) and non-destructive stubbed test suites for validation, service selection, UFW/nftables rule generation, bridge detection, and idempotency.

### Safety notes

- No database, Redis, S3, Docker API, or mail port is opened inbound by default.
- Dokploy and Coolify are never installed together automatically; the menu warns and requires a separate decision.
- The toolkit never creates a competing nftables policy when the documented existing `inet cloud_dev forward` chain is absent.
