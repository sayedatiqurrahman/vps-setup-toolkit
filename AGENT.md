# AGENT handoff — VPS SENTINEL v1.3.0

## Status

The v1.3.0 work is implemented in this checkout and is ready to be committed/tagged/published.

- Unified Service Access (menu 15 / `vps-setup service`) is in `scripts/firewall.sh` with its catalog in `config/services.conf`.
- Docker outbound rules now allow `ct state { new, established, related }`, fixing the SMTP/IMAPS TLS failure in `problem_case.md`.
- Only the toolkit-owned `VPS-MANAGED-DOCKER-JUMP` is managed; it is forced to position 1 in the parent chain so unrelated drops/verdict chains cannot make managed rules unreachable.
- `nft -c -f` errors are printed, and rejected rules are preserved at `/etc/vps-setup/nft-last-failed.rules` with parser output at `/etc/vps-setup/nft-validation.log`.
- DNS/domain routing is a separate main menu item, `16) DNS & Domain Routing (Cloudflare)`, and CLI `vps-setup dns ...` in `scripts/dns.sh`.
- DNS supports Cloudflare A/AAAA/CNAME upsert/delete, token storage at `/etc/vps-setup/cloudflare.token` (0600), domain state at `/etc/vps-setup/dns-domains.rules`, Cloudflare IP ranges at `/etc/vps-setup/cloudflare-ips.json`, and origin allow rules tracked in `/etc/vps-setup/cloudflare-origin.rules`.
- Generic DNS providers are supported as provider-agnostic state plus printable Traefik/Docker label guidance; no provider API calls are made outside Cloudflare.
- Latest targeted suites: firewall `99 passed, 0 failed`; DNS `13 passed, 0 failed`.

## Release commands

```bash
# From the repository root
bash tests/run-tests.sh

git add -A
git commit -m "feat: add unified service access, established egress fix and DNS routing"
git push origin main

git tag -a v1.3.0 -m "VPS SENTINEL v1.3.0"
git push origin v1.3.0

# Publish the checksum after GitHub creates the tag archive.
curl -fsSL https://github.com/sayedatiqurrahman/vps-setup-toolkit/archive/refs/tags/v1.3.0.tar.gz -o /tmp/v1.3.0.tar.gz
sha256sum /tmp/v1.3.0.tar.gz | awk '{print $1}' > /tmp/v1.3.0.sha256

git checkout checksums
git pull --ff-only origin checksums
cp /tmp/v1.3.0.sha256 v1.3.0.sha256
git add v1.3.0.sha256
git commit -m "checksum: v1.3.0"
git push origin checksums
git checkout main
```

Verify a fresh install reports `1.3.0`:

```bash
curl -fsSL https://raw.githubusercontent.com/sayedatiqurrahman/vps-setup-toolkit/v1.3.0/install.sh -o /tmp/install-v130.sh
sudo bash /tmp/install-v130.sh --install-only
sudo vps-setup --version
```

## Safety invariants

- Never flush the full nftables ruleset or replace a user table/chain/policy.
- Only toolkit-commented rules may be deleted or reordered.
- Do not expose databases, Redis, mail services, Docker API or every container port publicly.
- Do not change physical MTU, recreate Swarms, or bypass TLS verification.
- Keep the exact Unified Service Access submenu text and confirmation prompt unchanged.
- Keep new DNS work inside `scripts/dns.sh`, menu 16 and `vps-setup dns`; do not create a second firewall manager or watcher.

## Known release note

`install.sh` and docs are pinned to `v1.3.0`. Do not publish a fresh-install URL until the `checksums` branch contains `v1.3.0.sha256`, otherwise the installer intentionally refuses unverified downloads.
